import Foundation
import CommonCrypto
import CryptoKit

/// MiIO（小米 IoT 局域网协议）报文加解密。
///
/// 协议来源：Android 版「小米音响 v1.3.2」反编译结果（`com.xiaomi.miio.MiioLocalAPI` /
/// `JNIBridge`，底层 libmiio.so / libencryptor.so）所使用的小米局域网协议（Xiaomi IoT local
/// protocol，与 python-miio 等公开实现一致）。Java 层仅暴露 JNI，算法本体按公开协议在
/// Swift 中重写：
///
/// 报文格式（全部大端）：
/// ```
/// magic  (2B)  0x2131
/// length (4B)  完整包长度（= 32 + 密文长度）
/// unkown (4B)  0xFFFFFFFF
/// did    (4B)  device id
/// stamp  (4B)  设备时间戳（防重放）
/// payload     （可选）AES-128-CBC 密文
/// ```
/// 加密：key = MD5(tokenBytes)，iv = key；明文 = MD5(json) + json，零填充到 16 字节。
/// 握手（hello）：32 字节 header + 32 字节明文 token，length=0x20。
enum MiioCryptoError: Error {
    case invalidTokenLength
    case packetTooShort
    case badMagic
    case decryptFailed
    case md5Mismatch
}

struct MiioCrypto {

    /// magic 常量（网络字节序 0x2131）
    static let magic: [UInt8] = [0x21, 0x31]

    /// 由 32 位十六进制 token 字符串得到 16 字节 token bytes
    static func tokenBytes(fromHex hex: String) throws -> [UInt8] {
        let t = hex.lowercased()
        guard t.count == 32, t.allSatisfy({ $0.isHexDigit }) else {
            throw MiioCryptoError.invalidTokenLength
        }
        var out = [UInt8]()
        var idx = t.startIndex
        while idx < t.endIndex {
            let next = t.index(idx, offsetBy: 2)
            if let b = UInt8(t[idx..<next], radix: 16) {
                out.append(b)
            } else {
                throw MiioCryptoError.invalidTokenLength
            }
            idx = next
        }
        return out
    }

    /// AES-128-CBC 密钥与 IV：均为 MD5(tokenBytes)
    static func keyAndIV(forTokenBytes token: [UInt8]) -> (key: [UInt8], iv: [UInt8]) {
        let digest = Insecure.MD5.hash(data: Data(token))
        let key = Array(digest)
        return (key, key)
    }

    /// 组装 32 字节报文头
    private static func header(length: UInt32, did: UInt32, stamp: UInt32) -> [UInt8] {
        var h = [UInt8]()
        h += magic
        h += UInt32(length).bigEndianBytes
        h += [0xFF, 0xFF, 0xFF, 0xFF]
        h += did.bigEndianBytes
        h += stamp.bigEndianBytes
        return h
    }

    /// 握手包：header + 明文 token（用于 get_token / 设备发现）
    static func craftHello(tokenHex: String, did: UInt32 = 0xFFFFFFFF, stamp: UInt32 = 0xFFFFFFFF) throws -> Data {
        let token = try tokenBytes(fromHex: tokenHex)
        var p = header(length: 0x20, did: did, stamp: stamp)
        p += token
        return Data(p)
    }

    /// 加密 RPC 报文：header + AES-CBC(MD5(json)+json)
    static func encrypt(json: String, did: UInt32, stamp: UInt32, tokenHex: String) throws -> Data {
        let token = try tokenBytes(fromHex: tokenHex)
        let (key, iv) = keyAndIV(forTokenBytes: token)
        let jsonData = Data(json.utf8)
        let md5 = Data(Insecure.MD5.hash(data: jsonData))

        var plain = [UInt8]()
        plain += Array(md5)
        plain += Array(jsonData)
        // 零填充到 16 字节边界（Xiaomi 协议约定，非 PKCS7）
        let pad = (16 - plain.count % 16) % 16
        plain += [UInt8](repeating: 0, count: pad)

        let cipher = try aesCBC(operation: CCOperation(kCCEncrypt), data: Data(plain), key: Data(key), iv: Data(iv))

        var packet = header(length: UInt32(32 + cipher.count), did: did, stamp: stamp)
        packet += Array(cipher)
        return Data(packet)
    }

    /// 解密响应报文：取出密文 → AES-CBC 解密 → 校验 MD5 → 返回 JSON 明文
    static func decrypt(packet: Data, tokenHex: String) throws -> String {
        let token = try tokenBytes(fromHex: tokenHex)
        guard packet.count >= 32 else { throw MiioCryptoError.packetTooShort }
        let bytes = Array(packet)
        // 校验 magic
        guard bytes[0] == magic[0], bytes[1] == magic[1] else { throw MiioCryptoError.badMagic }
        let declaredLength = UInt32(bytes[4]) << 24 | UInt32(bytes[5]) << 16 | UInt32(bytes[6]) << 8 | UInt32(bytes[7])
        guard Int(declaredLength) == bytes.count else { throw MiioCryptoError.packetTooShort }

        let cipher = Data(bytes[32..<bytes.count])
        let (key, iv) = keyAndIV(forTokenBytes: token)
        var plain = try aesCBC(operation: CCOperation(kCCDecrypt), data: cipher, key: Data(key), iv: Data(iv))

        // 去除尾部零填充
        while let last = plain.last, last == 0 { plain.removeLast() }
        guard plain.count > 16 else { throw MiioCryptoError.decryptFailed }
        let md5 = plain.prefix(16)
        let body = plain.dropFirst(16)
        let expected = Data(Insecure.MD5.hash(data: body))
        guard md5 == expected else { throw MiioCryptoError.md5Mismatch }
        return String(data: body, encoding: .utf8) ?? ""
    }

    /// 解析报文头，返回 (did, stamp)
    static func parseHeader(_ packet: Data) -> (did: UInt32, stamp: UInt32) {
        let bytes = Array(packet.prefix(32))
        guard bytes.count >= 32 else { return (0xFFFFFFFF, 0xFFFFFFFF) }
        let did = UInt32(bytes[12]) << 24 | UInt32(bytes[13]) << 16 | UInt32(bytes[14]) << 8 | UInt32(bytes[15])
        let stamp = UInt32(bytes[16]) << 24 | UInt32(bytes[17]) << 16 | UInt32(bytes[18]) << 8 | UInt32(bytes[19])
        return (did, stamp)
    }

    // MARK: - CommonCrypto 封装

    private static func aesCBC(operation: CCOperation, data: Data, key: Data, iv: Data) throws -> Data {
        let keyLen = key.count
        let dataLen = data.count
        let outLen = dataLen + kCCBlockSizeAES128
        var out = [UInt8](repeating: 0, count: outLen)
        var moved = 0

        let status = key.withUnsafeBytes { keyPtr in
            iv.withUnsafeBytes { ivPtr in
                data.withUnsafeBytes { dataPtr in
                    CCCrypt(operation,
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(0), // 默认 CBC 模式，不加 PKCS7（Xiaomi 协议自行零填充）
                            keyPtr.baseAddress, keyLen,
                            ivPtr.baseAddress,
                            dataPtr.baseAddress, dataLen,
                            &out, outLen,
                            &moved)
                }
            }
        }
        guard status == kCCSuccess else { throw MiioCryptoError.decryptFailed }
        return Data(out.prefix(moved))
    }
}

private extension UInt32 {
    var bigEndianBytes: [UInt8] {
        [UInt8((self >> 24) & 0xFF), UInt8((self >> 16) & 0xFF), UInt8((self >> 8) & 0xFF), UInt8(self & 0xFF)]
    }
}
