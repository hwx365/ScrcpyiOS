//
//  VideoDecoder.swift
//  ScrcpyiOS
//
//  使用 VideoToolbox 做 H.264 硬件解码（拒绝软解，保证低延迟）。
//  输入：scrcpy 视频流解析出来的“一帧 H.264 Annex B 裸流”。
//  输出：CVPixelBuffer（NV12，即 420f），通过 onFrame 回调交给 Metal 渲染。
//
//  关键流程：
//   1. 从首帧里提取 SPS/PPS，创建 CMVideoFormatDescription
//   2. 创建 VTDecompressionSession（RealTime 低延迟）
//   3. 后续每一帧直接送进解码器，得到图像后回调
//

import Foundation
import VideoToolbox
import CoreMedia
import CoreVideo

final class VideoDecoder {
    private var session: VTDecompressionSession?
    private var formatDesc: CMVideoFormatDescription?

    /// 视频原始分辨率（由 scrcpy 编解码器元信息给出）
    var width: Int = 0
    var height: Int = 0

    /// 每解出一帧图像调用一次（主线程外，渲染层自行切线程）
    var onFrame: ((CVPixelBuffer) -> Void)?

    /// 解码器是否就绪（已拿到 SPS/PPS 并创建会话）
    private(set) var isReady = false

    // MARK: - 解码入口

    func decode(_ annexB: Data) {
        // 还没建立格式描述时，尝试从当前数据里抽取 SPS/PPS
        if formatDesc == nil {
            guard let (sps, pps) = Self.extractParameterSets(annexB) else {
                // 还没出现参数集，先缓存？这里简单丢弃，等待带 SPS/PPS 的帧
                return
            }
            createFormatDescription(sps: sps, pps: pps)
        }
        guard let session = session, let formatDesc = formatDesc else { return }

        // 用 CMBlockBuffer 包裹整段 Annex B（含 start code，VT 可识别）。
        // 注意：必须让 block buffer 自己持有内存副本，因为 VT 解码是异步的，
        // 不能引用 decode() 栈上的 Data 内存，否则解码时内存已被释放。
        var blockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: nil,
            memoryBlock: nil,           // 让 block buffer 自行分配并持有内存
            blockLength: annexB.count,
            blockAllocator: nil,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: annexB.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == kCMBlockBufferNoErr, let bb = blockBuffer else { return }
        status = annexB.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(
                with: raw.baseAddress!,
                offsetIntoDestination: 0,
                dataLength: annexB.count,
                destinationBlockBuffer: bb
            )
        }
        guard status == kCMBlockBufferNoErr else { return }

        var sampleBuffer: CMSampleBuffer?
        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: .invalid,
            decodeTimeStamp: .invalid
        )
        let sstatus = CMSampleBufferCreateReady(
            allocator: nil,
            dataBuffer: bb,
            formatDescription: formatDesc,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        )
        guard sstatus == noErr, let sbuf = sampleBuffer else { return }

        // 低延迟：解码出即显示，不要缓冲
        var dict: [String: Any] = [:]
        dict[kCMSampleAttachmentKey_DisplayImmediately as String] = true
        CMSampleBufferSetSampleAttachmentsArray(sbuf, value: [dict] as CFArray)

        var infoFlags: VTDecodeInfoFlags = []
        let err = VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sbuf,
            flags: VTDecodeFrameFlags(rawValue: 0),
            frameRefcon: nil,
            infoFlagsOut: &infoFlags
        )
        if err != noErr {
            // 解码失败（常见原因：参数集不匹配、帧损坏）。V1 简单忽略，避免崩溃。
            print("[VideoDecoder] decode frame error: \(err)")
        }
    }

    // MARK: - 格式描述与会话创建

    private func createFormatDescription(sps: Data, pps: Data) {
        var desc: CMVideoFormatDescription?
        let spsPtr = UnsafeMutablePointer<UInt8>.allocate(capacity: sps.count)
        spsPtr.initialize(from: Array(sps), count: sps.count)
        let ppsPtr = UnsafeMutablePointer<UInt8>.allocate(capacity: pps.count)
        ppsPtr.initialize(from: Array(pps), count: pps.count)

        let paramSets: [UnsafeMutablePointer<UInt8>?] = [spsPtr, ppsPtr]
        let paramSizes: [Int] = [sps.count, pps.count]

        // 注意：这里必须把指针数组转成 UnsafePointer，使用 withUnsafeBytes 风格较繁琐，
        // 直接用临时变量绑定。
        var status: OSStatus = 0
        paramSets.withUnsafeBufferPointer { buf in
            sps.withUnsafeBytes { _ in
                pps.withUnsafeBytes { _ in
                    status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                        allocator: nil,
                        parameterSetCount: 2,
                        parameterSetPointers: buf.baseAddress!,
                        parameterSetSizes: paramSizes,
                        nalUnitHeaderLength: 4,
                        formatDescriptionOut: &desc
                    )
                }
            }
        }
        spsPtr.deallocate()
        ppsPtr.deallocate()

        guard status == noErr, let d = desc else {
            print("[VideoDecoder] 创建格式描述失败: \(status)")
            return
        }
        self.formatDesc = d
        createSession()
    }

    private func createSession() {
        guard let desc = formatDesc else { return }
        var session: VTDecompressionSession?
        let callback: VTDecompressionOutputCallback = { decompressionOutputRefCon, _, status, _, imageBuffer, _, _ in
            guard status == noErr, let pixelBuffer = imageBuffer else { return }
            let decoder = Unmanaged<VideoDecoder>.fromOpaque(decompressionOutputRefCon!).takeUnretainedValue()
            decoder.onFrame?(pixelBuffer)
        }

        var callbacks = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: callback,
            decompressionOutputRefCon: Unmanaged.passUnretained(self).toOpaque()
        )

        // 低延迟：实时解码
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferOpenGLESCompatibilityKey as String: true
        ]

        let status = VTDecompressionSessionCreate(
            allocator: nil,
            formatDescription: desc,
            decoderSpecification: nil,
            imageBufferAttributes: attrs as CFDictionary,
            outputCallback: &callbacks,
            decompressionSessionOut: &session
        )
        guard status == noErr, let s = session else {
            print("[VideoDecoder] 创建解码会话失败: \(status)")
            return
        }
        // 设为实时，降低延迟、避免堆积
        VTSessionSetProperty(s, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        self.session = s
        self.isReady = true
    }

    func invalidate() {
        if let s = session {
            VTDecompressionSessionWaitForAsynchronousFrames(s)
            VTDecompressionSessionInvalidate(s)
        }
        session = nil
        formatDesc = nil
        isReady = false
    }

    // MARK: - 从 Annex B 中抽取 SPS/PPS

    /// 扫描一段 Annex B 数据，返回首个 SPS(7) 与 PPS(8)
    static func extractParameterSets(_ data: Data) -> (sps: Data, pps: Data)? {
        var sps: Data?
        var pps: Data?
        var i = 0
        while i + 4 <= data.count {
            // 找 start code: 00 00 00 01 或 00 00 01
            let isLong = (data[i] == 0 && data[i+1] == 0 && data[i+2] == 0 && data[i+3] == 1)
            let isShort = (!isLong && data[i] == 0 && data[i+1] == 0 && data[i+2] == 1)
            guard isLong || isShort else { i += 1; continue }
            let headerOffset = isLong ? i + 4 : i + 3
            guard headerOffset < data.count else { break }
            let nalHeader = data[headerOffset]
            let nalType = nalHeader & 0x1F
            // 找到下一个 start code 作为本 NAL 的结束
            let next = findNextStartCode(data, from: headerOffset + 1)
            let end = next == -1 ? data.count : next
            let nal = data.subdata(in: headerOffset..<end)
            if nalType == 7 { sps = nal }
            else if nalType == 8 { pps = nal }
            if sps != nil, pps != nil { break }
            i = (next == -1) ? data.count : next
        }
        if let s = sps, let p = pps { return (s, p) }
        return nil
    }

    private static func findNextStartCode(_ data: Data, from offset: Int) -> Int {
        var i = offset
        while i + 4 <= data.count {
            if data[i] == 0 && data[i+1] == 0 && data[i+2] == 0 && data[i+3] == 1 { return i }
            if data[i] == 0 && data[i+1] == 0 && data[i+2] == 1 { return i }
            i += 1
        }
        return -1
    }
}
