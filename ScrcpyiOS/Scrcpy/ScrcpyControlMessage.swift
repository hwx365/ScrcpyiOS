//
//  ScrcpyControlMessage.swift
//  ScrcpyiOS
//
//  构造发往 scrcpy-server 的控制消息（全部大端，顺序见 scrcpy app/src/control_msg.c）。
//
//  V1 只实现两类：
//   - 注入文本（打字，覆盖绝大多数输入场景）
//   - 注入触摸事件（按下/抬起/移动，单指）
//  物理按键（返回/Home/音量）等放到 V2（可用 INJECT_KEYCODE，常量已预留）。
//

import Foundation

struct ScrcpyControlMessage {
    // MARK: - 注入文本（控制消息类型 1）

    /// 把一段 UTF-8 文本发给安卓，服务端会转换为按键事件。
    /// 布局：type(u8) + length(u32 大端) + text(UTF-8, 不以 \0 结尾)
    static func injectText(_ text: String) -> Data {
        var d = Data()
        d.append(ScrcpyProtocol.CONTROL_TYPE_INJECT_TEXT)
        let bytes = Data(text.utf8)
        d.appendUInt32BE(UInt32(bytes.count))
        d.append(contentsOf: bytes)
        return d
    }

    // MARK: - 注入触摸事件（控制消息类型 2）

    /// 单指触摸事件。
    /// 布局（大端）：
    ///   type(u8=2) + action(u8) + pointerId(u64)
    ///   + x(u32) + y(u32) + screenWidth(u16) + screenHeight(u16)
    ///   + pressure(u16 定点 = pressure*0xFFFF) + action_button(u32) + buttons(u64)
    ///
    /// - Parameters:
    ///   - action: ScrcpyProtocol.ACTION_DOWN / UP / MOVE / CANCEL
    ///   - x,y: 已映射到安卓原生分辨率的绝对坐标
    ///   - screenWidth,screenHeight: 安卓屏幕原生分辨率（用于服务端换算）
    ///   - pressure: 0~1，按下时给 1.0，抬起时给 0
    static func injectTouch(action: UInt8,
                            x: UInt32,
                            y: UInt32,
                            screenWidth: UInt16,
                            screenHeight: UInt16,
                            pressure: Float = 1.0) -> Data {
        var d = Data()
        d.append(ScrcpyProtocol.CONTROL_TYPE_INJECT_TOUCH)
        d.append(action)
        d.appendUInt64BE(ScrcpyProtocol.FINGER_POINTER_ID)
        d.appendUInt32BE(x)
        d.appendUInt32BE(y)
        d.appendUInt16BE(screenWidth)
        d.appendUInt16BE(screenHeight)
        let p = UInt16(max(0, min(1, pressure)) * Float(0xFFFF))
        d.appendUInt16BE(p)
        d.appendUInt32BE(0) // action_button（手指触摸填 0）
        d.appendUInt64BE(0) // buttons（手指触摸填 0）
        return d
    }

    // MARK: - 注入物理按键（V2 预留，当前未使用）

    /// 物理按键（如返回 KEYCODE_BACK=4，Home 需要 shell 模拟，这里只是协议占位）。
    /// 布局：type(u8=0) + action(u8) + keycode(u32) + repeat(u32) + metastate(u32)
    static func injectKeycode(action: UInt8, keycode: UInt32) -> Data {
        var d = Data()
        d.append(ScrcpyProtocol.CONTROL_TYPE_INJECT_KEYCODE)
        d.append(action)
        d.appendUInt32BE(keycode)
        d.appendUInt32BE(0) // repeat count
        d.appendUInt32BE(0) // meta state
        return d
    }
}
