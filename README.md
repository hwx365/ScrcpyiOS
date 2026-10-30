# Scrcpy iOS 自用客户端（V1.0 MVP）

iPhone 控制安卓的 scrcpy 客户端，**仅自签、不上架 App Store**。
目标设备：主控端 iPhone；被控端一加 9 Pro（ColorOS，无线调试 5555）。
通信环境：安卓开热点，iPhone 接入，局域网内网 TCP 通信。

基于 scrcpy Apache-2.0 协议**独立实现** iOS 客户端，不直接移植原版 scrcpy 的 C 代码，
全部使用 iOS 原生框架：`Network`、`Security`、`VideoToolbox`、`Metal`。

## 功能范围（V1.0 MVP）
- ✅ ADB over TCP：CNXN 握手 + RSA 认证（密钥持久化，免重复授权）
- ✅ 自动拉起 scrcpy-server（shell 流），视频/控制双通道
- ✅ 视频：VideoToolbox 硬解 H.264 + Metal 渲染（拒绝软解，低延迟）
- ✅ 触摸：单指按下/移动/抬起，坐标归一化映射到安卓原生分辨率
- ✅ 键盘：软键盘文本注入转发
- ❌ 音频（V2）；❌ 多点触控/物理按键（V2）；❌ 上架逻辑

## 快速开始
详见 [`部署文档.md`](部署文档.md)：
1. 一加 9 Pro 开启无线调试（5555）。
2. 把官方 `scrcpy-server.jar` 推到 `/data/local/tmp/`。
3. Xcode 用 Apple ID 自签运行到 iPhone（7 天重签）。
4. App 内填安卓 IP → 连接并投屏。

## 模块说明
| 模块 | 位置 | 职责 |
|------|------|------|
| ADB | `ScrcpyiOS/ADB/` | TCP 连接、握手、RSA 认证、流多路复用 |
| Scrcpy 协议 | `ScrcpyiOS/Scrcpy/` | 启 server、开流、解析视频帧、构造控制消息 |
| 视频 | `ScrcpyiOS/Video/` | VideoToolbox 硬解 + Metal 渲染 |
| 输入 | `ScrcpyiOS/Input/` | 触摸映射 + 软键盘转发 |

> 协议版本敏感：scrcpy-server 与客户端需同大版本。易变参数集中在
> `ScrcpyProtocol.swift` 与 `ScrcpyConnection.buildLaunchCommand()`。
