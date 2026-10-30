//
//  ConnectionManager.swift
//  ScrcpyiOS
//
//  UI 与底层 ScrcpyConnection 的桥梁（ObservableObject）。
//  持有连接对象，把底层回调桥接成 SwiftUI 可用的 @Published 状态。
//

import Foundation
import SwiftUI
import CoreVideo

enum ConnectionStatus: String {
    case idle = "未连接"
    case connecting = "连接中…"
    case connected = "已连接（投屏中）"
    case failed = "连接失败"
}

final class ConnectionManager: ObservableObject {
    let connection = ScrcpyConnection()

    @Published var ipAddress: String = ""
    @Published var status: ConnectionStatus = .idle
    @Published var deviceName: String = ""
    @Published var logLines: [String] = []
    @Published var isConnected: Bool = false

    /// 供 UI 触发唤起软键盘（由 ScreenSurfaceRepresentable 注入实现）
    var requestKeyboard: (() -> Void)?

    private let logQueue = DispatchQueue(label: "com.scrcpy.log")

    init() {
        connection.onLog = { [weak self] msg in self?.appendLog(msg) }
        connection.onError = { [weak self] msg in
            self?.appendLog("❌ " + msg)
            DispatchQueue.main.async {
                self?.status = .failed
                self?.isConnected = false
            }
        }
        connection.onDeviceReady = { [weak self] name, w, h in
            DispatchQueue.main.async {
                self?.deviceName = name
                if w > 0 && h > 0 {
                    // 视频流已拿到真实分辨率，才算真正就绪
                    self?.status = .connected
                    self?.isConnected = true
                    self?.appendLog("✅ 设备就绪：\(name) \(w)x\(h)")
                } else {
                    self?.appendLog("ℹ️ 已识别设备：\(name)，等待视频流…")
                }
            }
        }
    }

    func connect() {
        let ip = ipAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ip.isEmpty else {
            appendLog("❌ 请先填写安卓设备 IP")
            return
        }
        status = .connecting
        appendLog("▶ 开始连接 \(ip)")
        connection.start(deviceIP: ip)
    }

    func disconnect() {
        connection.stop()
        isConnected = false
        status = .idle
    }

    /// 发送文本（来自软键盘）
    func sendText(_ text: String) {
        connection.sendText(text)
    }

    func focusKeyboard() {
        requestKeyboard?()
    }

    private func appendLog(_ message: String) {
        let ts = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        let line = "[\(ts)] \(message)"
        logQueue.async { [weak self] in
            DispatchQueue.main.async {
                self?.logLines.append(line)
                // 控制日志条数，避免无限增长
                if let count = self?.logLines.count, count > 500 {
                    self?.logLines.removeFirst(count - 500)
                }
            }
        }
    }
}
