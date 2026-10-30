//
//  ScrcpyConnection.swift
//  ScrcpyiOS
//
//  总编排：
//   1. 通过 ADB 连接安卓
//   2. 用 shell 流拉起 scrcpy-server.jar（前台运行，保持 shell 流打开以维持进程）
//   3. 依次打开“控制流”(localabstract:scrcpy) 与“视频流”(localabstract:scrcpy)
//      —— scrcpy 按连接顺序把首条当控制、第二条当视频
//   4. 控制流：读取哑元字节 + 设备名；并用于回传触摸/文本
//   5. 视频流：解析 codec 元信息 + 逐帧头，喂给 VideoToolbox 解码
//
//  V1 不含音频流（第三类），后续版本再加。
//

import Foundation
import CoreVideo

final class ScrcpyConnection {
    private let adb = ADBClient()
    private let decoder = VideoDecoder()

    /// 安卓屏幕原生分辨率（来自视频流 codec 元信息），触摸映射需要它
    private(set) var deviceWidth: UInt16 = 0
    private(set) var deviceHeight: UInt16 = 0
    private(set) var deviceName: String = "Android"

    private var shellStream: ADBStream?
    private var controlStream: ADBStream?
    private var videoStream: ADBStream?

    /// 控制流已收到的原始字节（用于解析哑元字节+设备名）
    private var controlBuffer = Data()
    private var deviceMetaParsed = false

    /// 视频流解析状态
    private var videoBuffer = Data()
    private var codecMetaParsed = false

    // MARK: - 对外回调 / 事件

    var onLog: ((String) -> Void)?
    var onVideoFrame: ((CVPixelBuffer) -> Void)?
    var onDeviceReady: ((_ name: String, _ width: Int, _ height: Int) -> Void)?
    var onError: ((String) -> Void)?

    init() {
        adb.onLog = { [weak self] in self?.onLog?($0) }
        decoder.onFrame = { [weak self] pixelBuffer in
            self?.onVideoFrame?(pixelBuffer)
        }
    }

    // MARK: - 启动

    func start(deviceIP: String, bitRate: Int = 10_000_000, maxSize: Int = 0) {
        onLog?("开始连接 \(deviceIP):5555 ...")
        adb.connect(host: deviceIP) { [weak self] result in
            switch result {
            case .success:
                self?.launchServerAndConnect(bitRate: bitRate, maxSize: maxSize)
            case .failure(let err):
                self?.onError?("ADB 连接失败: \(err.localizedDescription)")
            }
        }
    }

    // MARK: - 拉起 scrcpy-server 并建流

    private func launchServerAndConnect(bitRate: Int, maxSize: Int) {
        let cmd = Self.buildLaunchCommand(bitRate: bitRate, maxSize: maxSize)
        onLog?("发送启动命令：拉起 scrcpy-server ...")
        adb.openStream(destination: "shell:" + cmd) { [weak self] result in
            switch result {
            case .success(let stream):
                self?.shellStream = stream
                self?.onLog?("scrcpy-server 启动命令已下发，等待其监听抽象套接字...")
                self?.openControlAndVideo(retry: 0)
            case .failure(let err):
                self?.onError?("启动 scrcpy-server 失败: \(err.localizedDescription)")
            }
        }
    }

    /// 依次打开控制流、视频流（scrcpy 按连接顺序分配）
    private func openControlAndVideo(retry: Int) {
        guard retry < 50 else {
            self.onError?("无法连接 scrcpy 视频/控制通道，请确认 scrcpy-server 已正确运行（见部署文档排查）")
            return
        }
        adb.openStream(destination: ScrcpyProtocol.abstractSocketName) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let control):
                self.controlStream = control
                self.setupControlStream(control)
                // 控制流就绪后再开视频流（顺序很重要）
                self.adb.openStream(destination: ScrcpyProtocol.abstractSocketName) { result2 in
                    switch result2 {
                    case .success(let video):
                        self.videoStream = video
                        self.setupVideoStream(video)
                        self.onLog?("控制流与视频流均已建立，开始投屏")
                    case .failure:
                        // 视频流还没就绪，稍后重试（server 可能还在初始化）
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                            self.openControlAndVideo(retry: retry + 1)
                        }
                    }
                }
            case .failure:
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    self.openControlAndVideo(retry: retry + 1)
                }
            }
        }
    }

    // MARK: - 控制流解析（哑元字节 + 设备名）

    private func setupControlStream(_ stream: ADBStream) {
        stream.onData = { [weak self] data in
            self?.handleControlData(data)
        }
    }

    private func handleControlData(_ data: Data) {
        controlBuffer.append(data)
        guard !deviceMetaParsed else { return }

        var offset = 0
        // 1) 哑元字节（expectDummyByteOnControl 为 true 时先吃掉一个 0x00）
        if ScrcpyProtocol.expectDummyByteOnControl {
            if controlBuffer.count < 1 { return }
            offset = 1
        }
        // 2) 设备名长度
        let remaining = controlBuffer.subdata(in: offset..<controlBuffer.count)
        let lenSize = ScrcpyProtocol.deviceMetaLengthIsU32 ? 4 : 2
        if remaining.count < lenSize { return }
        let nameLen: Int = ScrcpyProtocol.deviceMetaLengthIsU32
            ? Int(remaining.readUInt32BE(at: 0))
            : Int(remaining.readUInt16BE(at: 0))
        if nameLen <= 0 || nameLen > 256 { return } // 非法长度，等更多数据或放弃
        if remaining.count < lenSize + nameLen { return }
        let nameData = remaining.subdata(in: lenSize..<lenSize + nameLen)
        if let name = String(data: nameData, encoding: .utf8) {
            deviceName = name
            onLog?("设备名：\(name)")
        }
        deviceMetaParsed = true
        onDeviceReady?(deviceName, Int(deviceWidth), Int(deviceHeight))
    }

    // MARK: - 视频流解析（codec 元信息 + 帧）

    private func setupVideoStream(_ stream: ADBStream) {
        stream.onData = { [weak self] data in
            self?.handleVideoData(data)
        }
    }

    private func handleVideoData(_ data: Data) {
        videoBuffer.append(data)

        // 1) 解析 codec 元信息（仅一次）
        if !codecMetaParsed {
            if videoBuffer.count < ScrcpyProtocol.codecMetaSize { return }
            let w = Int(videoBuffer.readUInt32BE(at: 4))
            let h = Int(videoBuffer.readUInt32BE(at: 8))
            deviceWidth = UInt16(min(w, 65535))
            deviceHeight = UInt16(min(h, 65535))
            decoder.width = w
            decoder.height = h
            videoBuffer.removeSubrange(0..<ScrcpyProtocol.codecMetaSize)
            codecMetaParsed = true
            onLog?("视频分辨率：\(w) x \(h)")
            onDeviceReady?(deviceName, w, h)
        }

        // 2) 逐帧解析：每帧 12 字节头 + size 字节 H.264
        while codecMetaParsed, videoBuffer.count >= ScrcpyProtocol.frameHeaderSize {
            let size = Int(videoBuffer.readUInt32BE(at: 8)) // 帧数据长度在头[8..12)
            guard videoBuffer.count >= ScrcpyProtocol.frameHeaderSize + size else { break }
            let frameData = videoBuffer.subdata(
                in: ScrcpyProtocol.frameHeaderSize..<ScrcpyProtocol.frameHeaderSize + size)
            videoBuffer.removeSubrange(0..<ScrcpyProtocol.frameHeaderSize + size)
            // 丢帧策略：只把最新帧交给解码器由渲染端覆盖即可，这里直接解码
            decoder.decode(frameData)
        }
    }

    // MARK: - 对外输入接口（供 TouchController / 键盘调用）

    /// 归一化坐标(0~1) -> 安卓绝对坐标，发送触摸
    func sendTouch(action: UInt8, normalizedX: Float, normalizedY: Float, pressure: Float = 1.0) {
        guard deviceWidth > 0, deviceHeight > 0 else { return }
        let x = UInt32(max(0, min(1, normalizedX)) * Float(deviceWidth))
        let y = UInt32(max(0, min(1, normalizedY)) * Float(deviceHeight))
        let msg = ScrcpyControlMessage.injectTouch(
            action: action, x: x, y: y,
            screenWidth: deviceWidth, screenHeight: deviceHeight,
            pressure: pressure)
        controlStream?.send(msg)
    }

    /// 发送文本（打字）
    func sendText(_ text: String) {
        guard !text.isEmpty else { return }
        controlStream?.send(ScrcpyControlMessage.injectText(text))
    }

    // MARK: - 断开

    func stop() {
        controlStream?.close()
        videoStream?.close()
        shellStream?.close()
        decoder.invalidate()
        adb.disconnect()
        onLog?("已断开")
    }

    // MARK: - 启动命令（scrcpy-server）

    /// 构造在安卓上拉起 scrcpy-server 的 shell 命令。
    /// ⚠️ 参数个数/顺序与 scrcpy-server.jar 版本强相关，本实现按 scrcpy 2.4 编写。
    ///    若你使用其它版本，请对照该版本 Server.java 的 main(String... args) 调整。
    static func buildLaunchCommand(bitRate: Int, maxSize: Int) -> String {
        let maxSizeArg = maxSize > 0 ? "\(maxSize)" : "0"
        let args = [
            maxSizeArg,            // 0 maxSize
            "\(bitRate)",          // 1 bitRate(bps)
            "true",                // 2 tunnelForward（对应本客户端的哑元字节逻辑）
            "\"\"",                // 3 crop
            "true",                // 4 control
            "0",                   // 5 displayId
            "false",               // 6 showTouches
            "false",               // 7 stayAwake
            "\"\"",                // 8 codecOptions
            "\"\"",                // 9 encoderName
            "false",               // 10 powerOffOnClose
            "false",               // 11 clipboardAutosync
            "true",                // 12 downsizeOnError
            "true",                // 13 sendDeviceMeta（控制流首部会发设备名）
            "true",                // 14 sendFrameMeta（每帧带 12 字节头）
            "0",                   // 15 scid
            "false",               // 16 audio（V1 关闭音频）
            "\"\"",                // 17 audioCodec
            "0",                   // 18 audioBitRate
            "0",                   // 19 audioChannelCount
            "0"                    // 20 audioSampleRate
        ]
        let argString = args.joined(separator: " ")
        // 前台运行：保持 shell 流打开即可让进程存活；关闭流时进程随之结束
        return "CLASSPATH=/data/local/tmp/scrcpy-server.jar app_process -Djava.library.path=/data/local/tmp -Dlog.level=info / com.genymobile.scrcpy.Server \(argString)"
    }
}
