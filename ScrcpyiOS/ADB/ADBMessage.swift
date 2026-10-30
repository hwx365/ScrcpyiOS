//
//  ADBMessage.swift
//  ScrcpyiOS
//
//  ADB 底层报文结构。参考 AOSP system/core/adb/protocol.txt。
//  每个报文固定 24 字节头 + 可选数据负载，全部小端。
//
//  头布局（每字段 4 字节，小端）：
//   [0]  command   命令字（见 ADBCommand）
//   [4]  arg0      通常为本端(local)流 id
//   [8]  arg1      通常为对端(remote)流 id
//   [12] data_length  数据长度
//   [16] data_check   校验和（官方实现常填 0，本客户端同样置 0）
//   [20] magic    = command ^ 0xFFFFFFFF
//

import Foundation

enum ADBCommand: UInt32 {
    case cnxn = 0x4E584E43  // "CNXN" 连接握手
    case auth = 0x48545541  // "AUTH"  密钥认证
    case open = 0x4E45504F  // "OPEN"  打开一条流（如 shell: / localabstract:）
    case okay = 0x59414F4B  // "OKAY"  确认
    case clse = 0x45534C43  // "CLSE"  关闭
    case wrte = 0x45545257  // "WRTE"  携带数据
}

enum ADBAuthType: UInt32 {
    case token = 1        // 设备发来的挑战 token，要求客户端签名
    case signature = 2    // 客户端用私钥签名后回传
    case rsaPublicKey = 3 // 客户端发送自己的公钥（首次需要手机端授权）
}

struct ADBMessage {
    let command: UInt32
    let arg0: UInt32
    let arg1: UInt32
    let dataLength: UInt32
    let dataCheck: UInt32
    let magic: UInt32
    var data: Data

    static let headerSize = 24

    init(command: UInt32, arg0: UInt32, arg1: UInt32, data: Data = Data()) {
        self.command = command
        self.arg0 = arg0
        self.arg1 = arg1
        self.dataLength = UInt32(data.count)
        self.dataCheck = 0
        self.magic = command ^ 0xFFFF_FFFF
        self.data = data
    }

    /// 序列化为网络字节
    func toData() -> Data {
        var out = Data(capacity: ADBMessage.headerSize + data.count)
        out.appendUInt32LE(command)
        out.appendUInt32LE(arg0)
        out.appendUInt32LE(arg1)
        out.appendUInt32LE(dataLength)
        out.appendUInt32LE(dataCheck)
        out.appendUInt32LE(magic)
        out.append(contentsOf: data)
        return out
    }

    /// 从 24 字节头 + 负载解析
    static func parse(header: Data, data: Data) -> ADBMessage? {
        guard header.count == headerSize else { return nil }
        return ADBMessage(
            command: header.readUInt32LE(at: 0),
            arg0: header.readUInt32LE(at: 4),
            arg1: header.readUInt32LE(at: 8),
            dataLength: header.readUInt32LE(at: 12),
            dataCheck: header.readUInt32LE(at: 16),
            magic: header.readUInt32LE(at: 20),
            data: data
        )
    }
}
