//
//  ScrcpyProtocol.swift
//  ScrcpyiOS
//
//  scrcpy 2.x 协议常量与字节布局约定（V1 仅用到视频与控制两条流）。
//
//  ⚠️ 协议版本敏感说明（非常重要）：
//  scrcpy 的“服务端/客户端”二进制协议属于内部协议，随版本变化。
//  本工程按 scrcpy 2.x（建议 2.4 ~ 2.7 任一版本）实现。请务必使用与之匹配的
//  官方原版 scrcpy-server.jar（由你自己准备并 push 到安卓）。
//  若启动失败或解析异常，请优先核对：
//    - 设备元信息长度字段（u32 / u16）
//    - 是否读取“哑元字节(dummy byte)”
//    - 启动参数个数/顺序（见 ScrcpyConnection.buildLaunchCommand）
//  这些点在不同 scrcpy 版本间可能不同，已在对应位置用常量暴露方便调整。
//

import Foundation

enum ScrcpyProtocol {
    /// scrcpy-server 监听的抽象套接字名（与启动参数中的 scid 相关，默认即 "scrcpy"）
    static let abstractSocketName = "localabstract:scrcpy"

    /// 使用 adb forward / 直接 OPEN 抽象套接字时，scrcpy 在“首条流(控制流)”上会先发一个
    /// 值为 0 的哑元字节（用于探测连接是否真正建立）。设为 true 表示先读掉该字节。
    /// 若你的 scrcpy-server 启动参数把 tunnelForward 设为 false，则应为 false。
    static let expectDummyByteOnControl = true

    /// 设备元信息（设备名）长度字段字节序：scrcpy 2.x 为 大端 u32。
    /// 如解析到的设备名乱码/长度异常，可尝试改成 u16（部分旧版本）。
    static let deviceMetaLengthIsU32 = true

    // MARK: - 视频流头部

    /// 视频流开头的“编解码器元信息”固定 12 字节（大端）：
    ///   [0..4)  codec id（4 字节 ASCII：'H','2','6','4' 等）
    ///   [4..8)  初始视频宽（u32 大端）
    ///   [8..12) 初始视频高（u32 大端）
    static let codecMetaSize = 12

    /// 每个视频帧前的帧头固定 12 字节（大端）：
    ///   [0..8)   pts(62bit) + 高 2 位标志位（bit63=keyframe, bit62=config）
    ///   [8..12)  本帧 H.264 数据长度（u32 大端）
    static let frameHeaderSize = 12

    // MARK: - 控制消息类型（客户端 -> 服务端）

    static let CONTROL_TYPE_INJECT_KEYCODE: UInt8 = 0
    static let CONTROL_TYPE_INJECT_TEXT: UInt8    = 1
    static let CONTROL_TYPE_INJECT_TOUCH: UInt8   = 2

    // MARK: - Android MotionEvent action（触屏）

    static let ACTION_DOWN: UInt8   = 0
    static let ACTION_UP: UInt8     = 1
    static let ACTION_MOVE: UInt8   = 2
    static let ACTION_CANCEL: UInt8 = 3

    /// 单指触摸使用的 pointerId（与 scrcpy 约定一致）
    static let FINGER_POINTER_ID: UInt64 = 0xFFFF_FFFF_FFFF_FFFF
}
