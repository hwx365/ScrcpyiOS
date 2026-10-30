//
//  TouchController.swift
//  ScrcpyiOS
//
//  投屏表面：底层是 Metal 渲染视图(ScreenMetalView)，上层透明捕获触摸。
//  触摸坐标归一化(0~1)后交给 ScrcpyConnection 映射到安卓原生分辨率。
//  V1 仅单指：touchesBegan=按下，touchesMoved=移动，touchesEnded/Cancelled=抬起。
//
//  键盘：内置一个隐藏 UITextField，唤起系统软键盘；每次落字通过
//  ScrcpyConnection.sendText 转发到安卓（V1 以文本注入为主）。
//

import UIKit
import CoreVideo
import SwiftUI

final class ScreenSurfaceView: UIView {
    // MARK: - 子视图
    private let metalView = ScreenMetalView()
    private let keyboardField = UITextField()

    /// 由外部(ConnectionManager)注入，用于发送触摸/文本
    weak var connection: ScrcpyConnection?

    /// 键盘请求回调（供 SwiftUI 工具栏按钮触发）
    var onRequestKeyboard: (() -> Void)?

    /// 当前追踪的触摸（单指）
    private var activeTouch: UITouch?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        backgroundColor = .black
        metalView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(metalView)
        NSLayoutConstraint.activate([
            metalView.leadingAnchor.constraint(equalTo: leadingAnchor),
            metalView.trailingAnchor.constraint(equalTo: trailingAnchor),
            metalView.topAnchor.constraint(equalTo: topAnchor),
            metalView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        // 隐藏的键盘输入框：透明、不换行、无自动更正
        keyboardField.translatesAutoresizingMaskIntoConstraints = false
        keyboardField.isHidden = true
        keyboardField.autocorrectionType = .no
        keyboardField.spellCheckingType = .no
        keyboardField.returnKeyType = .default
        keyboardField.delegate = self
        addSubview(keyboardField)
    }

    // MARK: - 视频帧入口
    func pushFrame(_ buffer: CVPixelBuffer) {
        metalView.displayPixelBuffer(buffer)
    }

    // MARK: - 键盘控制
    func focusKeyboard() {
        keyboardField.becomeFirstResponder()
    }

    // MARK: - 触摸捕获

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard activeTouch == nil, let touch = touches.first else { return }
        activeTouch = touch
        let (nx, ny) = normalize(touch)
        connection?.sendTouch(action: ScrcpyProtocol.ACTION_DOWN, normalizedX: nx, normalizedY: ny, pressure: 1.0)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = activeTouch, touches.contains(touch) else { return }
        let (nx, ny) = normalize(touch)
        connection?.sendTouch(action: ScrcpyProtocol.ACTION_MOVE, normalizedX: nx, normalizedY: ny, pressure: 1.0)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = activeTouch, touches.contains(touch) else { return }
        let (nx, ny) = normalize(touch)
        connection?.sendTouch(action: ScrcpyProtocol.ACTION_UP, normalizedX: nx, normalizedY: ny, pressure: 0.0)
        activeTouch = nil
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = activeTouch, touches.contains(touch) else { return }
        connection?.sendTouch(action: ScrcpyProtocol.ACTION_CANCEL, normalizedX: 0, normalizedY: 0, pressure: 0.0)
        activeTouch = nil
    }

    /// 把触摸点换算成视图内的归一化坐标(0~1)
    private func normalize(_ touch: UITouch) -> (Float, Float) {
        let point = touch.location(in: self)
        let nx = Float(point.x / bounds.width)
        let ny = Float(point.y / bounds.height)
        return (nx, ny)
    }
}

// MARK: - 键盘代理：逐字符转发

extension ScreenSurfaceView: UITextFieldDelegate {
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        // 回车：发送换行（V1 以文本注入方式，部分 App 可能不识别为回车，见文档）
        connection?.sendText("\n")
        textField.text = ""
        return false
    }

    func textField(_ textField: UITextField,
                   shouldChangeCharactersIn range: NSRange,
                   replacementString string: String) -> Bool {
        if string.isEmpty {
            // 删除键：发送退格字符（scrcpy 文本注入对退格支持有限，见文档 V2 改进）
            connection?.sendText("\u{8}")
        } else {
            connection?.sendText(string)
        }
        // 不真正插入，保持输入框为空以便持续捕获每次按键
        textField.text = ""
        return false
    }
}

// MARK: - SwiftUI 包装

struct ScreenSurfaceRepresentable: UIViewRepresentable {
    @ObservedObject var manager: ConnectionManager

    func makeUIView(context: Context) -> ScreenSurfaceView {
        let view = ScreenSurfaceView()
        view.connection = manager.connection
        // 视频帧回调：解码器 -> Metal
        manager.connection.onVideoFrame = { [weak view] buffer in
            DispatchQueue.main.async {
                view?.pushFrame(buffer)
            }
        }
        // 让管理器能请求唤起键盘
        manager.requestKeyboard = { [weak view] in
            view?.focusKeyboard()
        }
        return view
    }

    func updateUIView(_ uiView: ScreenSurfaceView, context: Context) {
        uiView.connection = manager.connection
    }
}
