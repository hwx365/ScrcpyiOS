//
//  ADBClient.swift
//  ScrcpyiOS
//
//  自实现的简易 ADB-over-TCP 客户端（仅局域网，适配 ColorOS 无线调试 5555 端口）。
//
//  职责：
//   1. TCP 连接安卓 IP:5555
//   2. CNXN 握手 + AUTH(RSA) 认证，认证通过后连接保持
//   3. 基于单条 TCP 连接做“流多路复用”(OPEN/OKAY/WRTE/CLSE)，
//      从而在同一条 ADB 连接上打开多条逻辑流（shell / localabstract 等）
//
//  重要：ADB 在同一条 TCP 上多路复用多条 stream，因此视频流与控制流
//  并不是各自独立的 TCP，而是被本类的流多路复用层拆开。
//

import Foundation
import Network

/// 一条 ADB 逻辑流（对应一次 OPEN）。
/// 例如 "shell:..." 或 "localabstract:scrcpy"。
final class ADBStream {
    let localId: UInt32
    weak var client: ADBClient?
    var remoteId: UInt32 = 0
    /// 标记 onReady 是否已触发，避免 OPEN 的 ACK 与后续数据 ACK 重复回调
    var isReady: Bool = false

    var onData: ((Data) -> Void)?
    var onReady: (() -> Void)?
    var onClose: (() -> Void)?

    init(localId: UInt32, client: ADBClient) {
        self.localId = localId
        self.client = client
    }

    func send(_ data: Data) {
        client?.streamSend(localId: localId, remoteId: remoteId, data: data)
    }

    func close() {
        client?.streamClose(localId: localId, remoteId: remoteId)
    }
}

final class ADBClient {
    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "com.scrcpy.adb.tcp")
    /// 回调队列（后台串行）：流数据/握手/完成回调都在此处理，避免阻塞主线程影响渲染。
    /// UI 相关的更新已在 ConnectionManager 中切回主线程。
    private let callbackQueue = DispatchQueue(label: "com.scrcpy.adb.callbacks")

    /// 流多路复用表（键为本端 localId）
    private var streams: [UInt32: ADBStream] = [:]
    private var nextLocalId: UInt32 = 0x0100_0001

    /// 接收缓冲（跨多次 TCP 读取累积，按 ADB 报文切分）
    private var incoming = Data()

    /// 握手状态机
    private enum Handshake { case idle, awaitingAuthOrCnxn, awaitingCnxnAfterPubkey, done }
    private var handshake: Handshake = .idle
    /// 是否已经用签名回应过一次 token（用于识别“二次挑战”）
    private var alreadySigned = false

    private var connectCompletion: ((Result<Void, Error>) -> Void)?

    var onLog: ((String) -> Void)?

    // MARK: - 连接与握手

    func connect(host: String, port: UInt16 = 5555, completion: @escaping (Result<Void, Error>) -> Void) {
        self.connectCompletion = completion
        let conn = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(integerLiteral: port),
            using: .tcp
        )
        self.connection = conn
        conn.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                self.onLog?("TCP 已连接 \(host):\(port)")
                self.startReading()
                self.beginHandshake()
            case .waiting(let err):
                self.onLog?("连接等待中: \(err.localizedDescription)")
            case .failed(let err):
                self.callbackQueue.async { completion(.failure(err)) }
            default:
                break
            }
        }
        conn.start(queue: queue)
    }

    private func beginHandshake() {
        handshake = .awaitingAuthOrCnxn
        alreadySigned = false
        // CNXN：版本 0x01000000，最大负载 0x40000；banner 固定为 "host::"，需以 \0 结尾
        let banner = "host::\0".data(using: .utf8)!
        let msg = ADBMessage(command: ADBCommand.cnxn.rawValue,
                             arg0: 0x0100_0000, arg1: 0x0004_0000, data: banner)
        sendMessage(msg)
    }

    // MARK: - 认证处理

    private func handleAuth(_ msg: ADBMessage) {
        let type = msg.arg0
        if type == ADBAuthType.token.rawValue {
            // 设备下发挑战 token
            if alreadySigned {
                // 二次挑战：说明上一轮签名未被信任，改发公钥，请用户在手机上授权
                sendPublicKey()
                handshake = .awaitingCnxnAfterPubkey
            } else {
                // 首次挑战：用本地私钥签名后回传
                do {
                    let sig = try ADBKeyManager.shared.sign(msg.data)
                    let resp = ADBMessage(command: ADBCommand.auth.rawValue,
                                          arg0: ADBAuthType.signature.rawValue,
                                          arg1: 0, data: sig)
                    sendMessage(resp)
                    alreadySigned = true
                    onLog?("已用本地密钥对 token 签名并回传，等待设备确认")
                } catch {
                    onLog?("token 签名失败: \(error.localizedDescription)")
                }
            }
        } else if type == ADBAuthType.rsaPublicKey.rawValue {
            // 设备要求公钥（罕见分支，直接再发一次公钥）
            sendPublicKey()
        }
    }

    private func sendPublicKey() {
        let pub = ADBKeyManager.shared.adbPublicKeyString().data(using: .utf8)!
        let resp = ADBMessage(command: ADBCommand.auth.rawValue,
                              arg0: ADBAuthType.rsaPublicKey.rawValue,
                              arg1: 0, data: pub)
        sendMessage(resp)
        onLog?("已发送 RSA 公钥，请在手机上点击「允许 USB 调试」")
    }

    // MARK: - 接收与多路复用分发

    private func startReading() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            if let data = data, !data.isEmpty {
                self.incoming.append(data)
                self.processIncoming()
            }
            if isComplete || error != nil {
                self.onLog?("ADB 连接断开: \(error?.localizedDescription ?? "EOF")")
                return
            }
            self.startReading()
        }
    }

    private func processIncoming() {
        while incoming.count >= ADBMessage.headerSize {
            let header = incoming.subdata(in: 0..<ADBMessage.headerSize)
            let dataLen = header.readUInt32LE(at: 12)
            guard incoming.count >= ADBMessage.headerSize + Int(dataLen) else { break }
            let payload = incoming.subdata(in: ADBMessage.headerSize..<ADBMessage.headerSize + Int(dataLen))
            incoming.removeSubrange(0..<ADBMessage.headerSize + Int(dataLen))
            guard let msg = ADBMessage.parse(header: header, data: payload) else { continue }
            dispatch(msg)
        }
    }

    private func dispatch(_ msg: ADBMessage) {
        switch msg.command {
        case ADBCommand.cnxn.rawValue:
            // 认证完成，连接就绪
            if handshake != .done {
                handshake = .done
                onLog?("ADB 认证成功，连接已就绪")
                let completion = connectCompletion
                connectCompletion = nil
                callbackQueue.async { completion?(.success(())) }
            }
            return

        case ADBCommand.auth.rawValue:
            handleAuth(msg)
            return

        default:
            break
        }

        guard handshake == .done else { return }

        // 收到报文中 arg1 表示“对端视角下的本端 localId”，用它来路由到对应流
        let ourLocalId = msg.arg1
        switch msg.command {
        case ADBCommand.okay.rawValue:
            if let stream = streams[ourLocalId] {
                stream.remoteId = msg.arg0
                if !stream.isReady {
                    stream.isReady = true
                    callbackQueue.async { stream.onReady?() }
                }
            }
        case ADBCommand.wrte.rawValue:
            if let stream = streams[ourLocalId] {
                let data = msg.data
                callbackQueue.async { stream.onData?(data) }
                // 必须回 OKAY 确认，否则设备会停止发送
                let ack = ADBMessage(command: ADBCommand.okay.rawValue,
                                     arg0: ourLocalId, arg1: stream.remoteId, data: Data())
                sendMessage(ack)
            }
        case ADBCommand.clse.rawValue:
            if let stream = streams[ourLocalId] {
                callbackQueue.async { stream.onClose?() }
                streams.removeValue(forKey: ourLocalId)
            }
        default:
            break
        }
    }

    // MARK: - 流操作

    /// 打开一条 ADB 流（如 "shell:..." 或 "localabstract:scrcpy"）
    func openStream(destination: String, completion: @escaping (Result<ADBStream, Error>) -> Void) {
        guard handshake == .done else {
            completion(.failure(NSError(domain: "ADB", code: -3, userInfo: [NSLocalizedDescriptionKey: "尚未完成 ADB 握手"])))
            return
        }
        let localId = nextLocalId
        nextLocalId += 1
        let stream = ADBStream(localId: localId, client: self)
        streams[localId] = stream
        stream.onReady = { completion(.success(stream)) }

        let destData = (destination + "\0").data(using: .utf8)!
        let open = ADBMessage(command: ADBCommand.open.rawValue,
                              arg0: localId, arg1: 0, data: destData)
        sendMessage(open)
    }

    fileprivate func streamSend(localId: UInt32, remoteId: UInt32, data: Data) {
        guard remoteId != 0 else {
            onLog?("流尚未就绪(localId=\(localId))，丢弃发送")
            return
        }
        let msg = ADBMessage(command: ADBCommand.wrte.rawValue,
                             arg0: localId, arg1: remoteId, data: data)
        sendMessage(msg)
    }

    fileprivate func streamClose(localId: UInt32, remoteId: UInt32) {
        let msg = ADBMessage(command: ADBCommand.clse.rawValue,
                             arg0: localId, arg1: remoteId, data: Data())
        sendMessage(msg)
        streams.removeValue(forKey: localId)
    }

    // MARK: - 发送

    private func sendMessage(_ msg: ADBMessage) {
        let data = msg.toData()
        queue.async { [weak self] in
            self?.connection?.send(content: data, completion: .contentProcessed({ _ in }))
        }
    }

    func disconnect() {
        connection?.cancel()
        connection = nil
        streams.removeAll()
        handshake = .idle
    }
}
