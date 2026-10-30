//
//  DataExtensions.swift
//  ScrcpyiOS
//
//  ADB 协议使用小端(LE)，scrcpy 协议使用大端(BE)。
//  这里集中提供两端字节序的读写辅助，避免散落各处造成字节序错误。
//
//  注意：全部用逐字节运算实现，不依赖 withUnsafeBytes，
//  避免在 Data 扩展里被解析成 Data 的实例方法而编译失败。
//

import Foundation

extension Data {
    /// 大端 16 位读取
    func readUInt16BE(at offset: Int) -> UInt16 {
        guard count >= offset + 2 else { return 0 }
        return (UInt16(self[offset]) << 8) | UInt16(self[offset + 1])
    }

    /// 大端 32 位读取
    func readUInt32BE(at offset: Int) -> UInt32 {
        guard count >= offset + 4 else { return 0 }
        var v: UInt32 = 0
        for i in 0..<4 { v = (v << 8) | UInt32(self[offset + i]) }
        return v
    }

    /// 大端 64 位读取
    func readUInt64BE(at offset: Int) -> UInt64 {
        guard count >= offset + 8 else { return 0 }
        var v: UInt64 = 0
        for i in 0..<8 { v = (v << 8) | UInt64(self[offset + i]) }
        return v
    }

    /// 小端 32 位读取（ADB 头使用）
    func readUInt32LE(at offset: Int) -> UInt32 {
        guard count >= offset + 4 else { return 0 }
        var v: UInt32 = 0
        for i in 0..<4 { v |= UInt32(self[offset + i]) << (8 * i) }
        return v
    }

    /// 大端追加
    mutating func appendUInt16BE(_ v: UInt16) {
        append(UInt8((v >> 8) & 0xFF))
        append(UInt8(v & 0xFF))
    }

    mutating func appendUInt32BE(_ v: UInt32) {
        append(UInt8((v >> 24) & 0xFF))
        append(UInt8((v >> 16) & 0xFF))
        append(UInt8((v >> 8) & 0xFF))
        append(UInt8(v & 0xFF))
    }

    mutating func appendUInt64BE(_ v: UInt64) {
        var shift = 56
        while shift >= 0 {
            append(UInt8((v >> UInt64(shift)) & 0xFF))
            shift -= 8
        }
    }

    /// 小端追加（ADB 头使用）
    mutating func appendUInt32LE(_ v: UInt32) {
        append(UInt8(v & 0xFF))
        append(UInt8((v >> 8) & 0xFF))
        append(UInt8((v >> 16) & 0xFF))
        append(UInt8((v >> 24) & 0xFF))
    }

    /// 安全取出单字节
    func byte(at offset: Int) -> UInt8? {
        guard offset >= 0, offset < count else { return nil }
        return self[offset]
    }
}
