//
//  ADBKeyManager.swift
//  ScrcpyiOS
//
//  负责 ADB 认证所需的 RSA 密钥：
//   - 首次使用时生成 RSA-2048 密钥对，私钥持久化到 Keychain（避免每次连接都要手机点允许）
//   - 导出 ADB 约定的公钥字符串："ssh-rsa <base64> <comment>"
//   - 对设备下发的 token 做 RSA + SHA1 + PKCS#1 v1.5 签名
//
//  说明：adb 使用的签名算法固定为 RSASSA-PKCS1-v1_5 with SHA-1，
//  公钥格式为 OpenSSH 的 ssh-rsa 线格式，这与 scrcpy / adb 官方一致。
//

import Foundation
import Security

final class ADBKeyManager {
    static let shared = ADBKeyManager()

    /// Keychain 中私钥的标识
    private let keyTag = "com.scrcpy.ios.adb.privatekey"
    private let comment = "scrcpy-ios@localhost"

    private var privateKey: SecKey?
    private var publicKey: SecKey?

    private init() {
        loadOrGenerate()
    }

    // MARK: - 密钥加载 / 生成

    private func loadOrGenerate() {
        if let existing = loadPrivateKey() {
            self.privateKey = existing
            self.publicKey = SecKeyCopyPublicKey(existing)
            return
        }
        generateNewKey()
    }

    private func loadPrivateKey() -> SecKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: keyTag.data(using: .utf8)!,
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecReturnRef as String: true
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else { return nil }
        return (item as! SecKey)
    }

    private func generateNewKey() {
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 2048,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: true,
                kSecAttrApplicationTag as String: keyTag.data(using: .utf8)!
            ]
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            // SecKeyCreateRandomKey 在旧系统上可能不支持 RSA，降级用 SecKeyGeneratePair
            generateLegacy()
            return
        }
        self.privateKey = key
        self.publicKey = SecKeyCopyPublicKey(key)
    }

    /// 兼容旧系统的降级生成方式（SecKeyGeneratePair 已废弃但可用）
    private func generateLegacy() {
        var pub: SecKey?
        var priv: SecKey?
        let status = SecKeyGeneratePair([
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 2048
        ] as CFDictionary, &pub, &priv)
        guard status == errSecSuccess, let priv = priv else { return }
        // 存到 Keychain
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: keyTag.data(using: .utf8)!,
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecValueRef as String: priv
        ]
        SecItemAdd(query as CFDictionary, nil)
        self.privateKey = priv
        self.publicKey = pub
    }

    // MARK: - 公钥导出（OpenSSH ssh-rsa 格式）

    /// 返回 ADB 使用的公钥字符串："ssh-rsa AAAA... comment"
    func adbPublicKeyString() -> String {
        guard let pub = publicKey,
              let der = SecKeyCopyExternalRepresentation(pub, nil) as Data?,
              let (modulus, exponent) = parseRSAPublicKeyDER(der) else {
            return ""
        }
        let blob = sshRSAPublicKeyBlob(modulus: modulus, exponent: exponent)
        let b64 = blob.base64EncodedString()
        return "ssh-rsa \(b64) \(comment)"
    }

    /// 把 RSA 公钥 DER(PKCS#1) 解析为 modulus / exponent
    private func parseRSAPublicKeyDER(_ der: Data) -> (modulus: Data, exponent: Data)? {
        var offset = 0
        // SEQUENCE
        guard der.byte(at: offset) == 0x30 else { return nil }
        offset += 1
        _ = readDERLength(der, &offset) // 跳过总长度
        // INTEGER modulus
        guard der.byte(at: offset) == 0x02 else { return nil }
        offset += 1
        let modLen = readDERLength(der, &offset)
        let modEnd = offset + modLen
        guard modEnd <= der.count else { return nil }
        var modulus = der.subdata(in: offset..<modEnd); offset = modEnd
        while modulus.count > 1, let f = modulus.first, f == 0x00 {
            modulus.removeFirst()
        }
        // INTEGER exponent
        guard der.byte(at: offset) == 0x02 else { return nil }
        offset += 1
        let expLen = readDERLength(der, &offset)
        let expEnd = offset + expLen
        guard der.count >= expEnd else { return nil }
        var exponent = der.subdata(in: offset..<expEnd)
        while exponent.count > 1, let f = exponent.first, f == 0x00 {
            exponent.removeFirst()
        }
        return (modulus, exponent)
    }

    /// 组装 OpenSSH 线格式：string("ssh-rsa") + mpint(e) + mpint(n)
    private func sshRSAPublicKeyBlob(modulus: Data, exponent: Data) -> Data {
        var blob = Data()
        let algo = "ssh-rsa".data(using: .utf8)!
        blob.appendUInt32BE(UInt32(algo.count))
        blob.append(contentsOf: algo)

        var exp = exponent
        if let first = exp.first, first & 0x80 != 0 { exp.insert(0x00, at: 0) }
        blob.appendUInt32BE(UInt32(exp.count))
        blob.append(contentsOf: exp)

        var mod = modulus
        if let first = mod.first, first & 0x80 != 0 { mod.insert(0x00, at: 0) }
        blob.appendUInt32BE(UInt32(mod.count))
        blob.append(contentsOf: mod)
        return blob
    }

    /// DER 长度解析，支持短形式与长形式
    private func readDERLength(_ data: Data, _ offset: inout Int) -> Int {
        guard let first = data.byte(at: offset) else { return 0 }
        offset += 1
        if first < 0x80 {
            return Int(first)
        }
        let numBytes = Int(first & 0x7F)
        var length = 0
        for _ in 0..<numBytes {
            length = (length << 8) | Int(data.byte(at: offset) ?? 0)
            offset += 1
        }
        return length
    }

    // MARK: - 签名

    /// 对 token 做 RSA-SHA1-PKCS1v15 签名，返回 256 字节签名
    func sign(_ token: Data) throws -> Data {
        guard let key = privateKey else { throw NSError(domain: "ADBKey", code: -1) }
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(
            key,
            .rsaSignatureMessagePKCS1v15SHA1,
            token as CFData,
            &error
        ) as Data? else {
            throw error?.takeRetainedValue() ?? NSError(domain: "ADBKey", code: -2)
        }
        return signature
    }
}
