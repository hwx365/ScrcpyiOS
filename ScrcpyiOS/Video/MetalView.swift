//
//  MetalView.swift
//  ScrcpyiOS
//
//  用 Metal 把 VideoToolbox 解出的 NV12(CVPixelBuffer) 实时渲染到屏幕。
//  不使用任何软解/第三方库，全部走系统 GPU。
//
//  设计：
//   - ScreenMetalView 继承 MTKView，由 Renderer 负责绘制
//   - Renderer 用 CVMetalTextureCache 把 CVPixelBuffer 的两个平面(Y / CbCr)
//     映射成 Metal 纹理，片元着色器做 YCbCr→RGB（BT.601 limited range）
//   - 只保留“最新一帧”，新帧到达时直接覆盖，天然实现丢帧、避免堆积
//

import Foundation
import Metal
import MetalKit
import CoreVideo

/// 内嵌的 Metal 着色器源码（无需额外的 .metal 资源文件）
private let shaderSource = """
#include <metal_stdlib>
using namespace metal;

struct VertexOut {
    float4 position [[position]];
    float2 texCoord;
};

// 全屏四边形顶点（triangleStrip）
vertex VertexOut vertexShader(uint vid [[vertex_id]],
                              constant float2 *verts [[buffer(0)]]) {
    VertexOut out;
    float2 p = verts[vid];
    out.position = float4(p, 0.0, 1.0);
    out.texCoord = (p * 0.5) + 0.5;
    out.texCoord.y = 1.0 - out.texCoord.y; // 纹理坐标翻转，避免画面上下颠倒
    return out;
}

// BT.601 limited range 转换矩阵
constant float3x3 ycbcrToRGB = float3x3(
    float3(1.0,  1.0,       1.0),
    float3(0.0, -0.344136,  1.772),
    float3(1.402, -0.714136, 0.0)
);

fragment float4 fragmentShader(VertexOut in [[stage_in]],
                               texture2d<float> yTex [[texture(0)]],
                               texture2d<float> cbcrTex [[texture(1)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float y = yTex.sample(s, in.texCoord).r;
    float2 cbcr = cbcrTex.sample(s, in.texCoord).rg;
    float3 ycbcr = float3(y, cbcr.x, cbcr.y);
    // limited range 偏移
    ycbcr.x = ycbcr.x - 16.0 / 255.0;
    ycbcr.y = ycbcr.y - 128.0 / 255.0;
    ycbcr.z = ycbcr.z - 128.0 / 255.0;
    float3 rgb = ycbcrToRGB * ycbcr;
    return float4(clamp(rgb, 0.0, 1.0), 1.0);
}
"""

final class ScreenRenderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    let pipeline: MTLRenderPipelineState
    var textureCache: CVMetalTextureCache?

    /// 仅保留最新一帧
    private var latestBuffer: CVPixelBuffer?
    private let lock = NSLock()

    init(device: MTLDevice) throws {
        self.device = device
        self.commandQueue = device.makeCommandQueue()!

        let lib = try device.makeLibrary(source: shaderSource, options: nil)
        let vfn = lib.makeFunction(name: "vertexShader")!
        let ffn = lib.makeFunction(name: "fragmentShader")!

        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = vfn
        desc.fragmentFunction = ffn
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm
        self.pipeline = try device.makeRenderPipelineState(descriptor: desc)

        CVMetalTextureCacheCreate(nil, nil, device, nil, &textureCache)
        super.init()
    }

    /// 由解码器回调调用：提交最新帧并请求重绘
    func setPixelBuffer(_ buffer: CVPixelBuffer) {
        lock.lock()
        latestBuffer = buffer
        lock.unlock()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // 视图尺寸变化时无需处理，渲染按 drawable 自适应
    }

    func draw(in view: MTKView) {
        lock.lock()
        let buffer = latestBuffer
        lock.unlock()
        guard let pixelBuffer = buffer else { return }
        render(pixelBuffer: pixelBuffer, view: view)
    }

    private func render(pixelBuffer: CVPixelBuffer, view: MTKView) {
        guard let textureCache = textureCache,
              let drawable = view.currentDrawable,
              let renderPass = view.currentRenderPassDescriptor else { return }

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        // 平面 0：Y（r8）
        var yTex: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(
            nil, textureCache, pixelBuffer, nil,
            .r8Unorm, width, height, 0, &yTex)
        // 平面 1：CbCr（rg8）
        var cbcrTex: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(
            nil, textureCache, pixelBuffer, nil,
            .rg8Unorm, width / 2, height / 2, 1, &cbcrTex)
        guard let yMetal = yTex, let cbcrMetal = cbcrTex,
              let yTexture = CVMetalTextureGetTexture(yMetal),
              let cbcrTexture = CVMetalTextureGetTexture(cbcrMetal) else { return }

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPass) else { return }

        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(yTexture, index: 0)
        encoder.setFragmentTexture(cbcrTexture, index: 1)
        encoder.setVertexBytes(fullscreenQuad, length: MemoryLayout<float2>.stride * 4, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    /// 全屏四边形（triangleStrip 顺序）
    private let fullscreenQuad: [float2] = [
        float2(-1, -1), float2(1, -1), float2(-1, 1), float2(1, 1)
    ]
}

/// MTKView 子类，SwiftUI 通过 Representable 包装使用
final class ScreenMetalView: MTKView {
    var renderer: ScreenRenderer?

    convenience init() {
        let device = MTLCreateSystemDefaultDevice()!
        self.init(frame: .zero, device: device)
        self.device = device
        self.framebufferOnly = false
        self.colorPixelFormat = .bgra8Unorm
        self.isPaused = true
        self.enableSetNeedsDisplay = true
        self.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        self.autoResizeDrawable = true
        if let renderer = try? ScreenRenderer(device: device) {
            self.renderer = renderer
            self.delegate = renderer
        }
    }

    /// 外部（解码器）调用，传入最新帧
    func displayPixelBuffer(_ buffer: CVPixelBuffer) {
        renderer?.setPixelBuffer(buffer)
        setNeedsDisplay()
    }
}
