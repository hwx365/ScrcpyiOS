//
//  DataExtensions.swift
//  ScrcpyiOS
//
//  ADB 协议使用小端(LE)，scrcpy 协议使用大端(BE)。
//  这里集中提供两端字节序的读写辅助，避免散落各处造成字节序错误。
//

import Foundation

extension Data {
    /// 大端 16 位读取
    func readUInt16BE(at offset: Int) -> UInt16 {
        guard count >= offset + 2 else { return 0 }
        var v: UInt16 = 0
        let sub = subdata(in: offset..<offset + 2)
        _ = withUnsafeMutableBytes(of: &v) { sub.copyBytes(to: $0) }
        return UInt16(bigEndian: v)
    }

    /// 大端 32 位读取
    func readUInt32BE(at offset: Int) -> UInt32 {
        guard count >= offset + 4 else { return 0 }
        var v: UInt32 = 0
        let sub = subdata(in: offset..<offset + 4)
        _ = withUnsafeMutableBytes(of: &v) { sub.copyBytes(to: $0) }
        return UInt32(bigEndian: v)
    }

    /// 大端 64 位读取
    func readUInt64BE(at offset: Int) -> UInt64 {
        guard count >= offset + 8 else { return 0 }
        var v: UInt64 = 0
        let sub = subdata(in: offset..<offset + 8)
        _ = withUnsafeMutableBytes(of: &v) { sub.copyBytes(to: $0) }
        return UInt64(bigEndian: v)
    }

    /// 小端 32 位读取（ADB 头使用）
    func readUInt32LE(at offset: Int) -> UInt32 {
        guard count >= offset + 4 else { return 0 }
        var v: UInt32 = 0
        let sub = subdata(in: offset..<offset + 4)
        _ = withUnsafeMutableBytes(of: &v) { sub.copyBytes(to: $0) }
        return UInt32(littleEndian: v)
    }

    /// 大端追加
    mutating func appendUInt16BE(_ v: UInt16) {
        var value = v.bigEndian
        append(contentsOf: withUnsafeBytes(of: &value) { Data($0) })
    }

    mutating func appendUInt32BE(_ v: UInt32) {
        var value = v.bigEndian
        append(contentsOf: withUnsafeBytes(of: &value) { Data($0) })
    }

    mutating func appendUInt64BE(_ v: UInt64) {
        var value = v.bigEndian
        append(contentsOf: withUnsafeBytes(of: &value) { Data($0) })
    }

    /// 小端追加（ADB 头使用）
    mutating func appendUInt32LE(_ v: UInt32) {
        var value = v.littleEndian
        append(contentsOf: withUnsafeBytes(of: &value) { Data($0) })
    }

    /// 安全取出单字节
    func byte(at offset: Int) -> UInt8? {
        guard offset < count else { return nil }
        return self[offset]
    }
}
