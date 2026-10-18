import CommonCrypto
import CryptoKit
import Foundation

/// Encryption negotiated during login. Only control messages are encrypted; the video
/// payload is sent in the clear unless the camera selects `fullAes`.
public enum BCEncryption: Sendable, Equatable {
    /// Very old firmware: everything in the clear.
    case unencrypted
    /// Firmware before ~2021: XOR with a fixed 8-byte key.
    case bcEncrypt
    /// AES-128-CFB keyed from the login nonce and the password.
    case aes(key: [UInt8])
    /// Same as `aes`, but the media stream is encrypted too.
    case fullAes(key: [UInt8])

    public var isAES: Bool {
        switch self {
        case .aes, .fullAes: return true
        default: return false
        }
    }

    public var name: String {
        switch self {
        case .unencrypted: return "none"
        case .bcEncrypt: return "BCEncrypt (XOR)"
        case .aes: return "AES-128-CFB"
        case .fullAes: return "AES-128-CFB (full)"
        }
    }

    /// `offset` is the channel id from the packet header (it seeds the XOR scheme).
    public func encrypt(offset: UInt32, _ data: Data) -> Data {
        switch self {
        case .unencrypted: return data
        case .bcEncrypt: return BCCrypto.xor(offset: offset, data)
        case .aes(let key), .fullAes(let key): return BCCrypto.cfbEncrypt(key: key, data)
        }
    }

    public func decrypt(offset: UInt32, _ data: Data) -> Data {
        switch self {
        case .unencrypted: return data
        case .bcEncrypt: return BCCrypto.xor(offset: offset, data)
        case .aes(let key), .fullAes(let key): return BCCrypto.cfbDecrypt(key: key, data)
        }
    }
}

public enum BCCrypto {
    static let xorKey: [UInt8] = [0x1F, 0x2D, 0x3C, 0x4B, 0x5A, 0x69, 0x78, 0xFF]
    public static let aesIV: [UInt8] = Array("0123456789abcdef".utf8)

    /// BCEncrypt: byte i is XORed with key[(offset % 8 + i) % 8] and with the low byte of offset.
    public static func xor(offset: UInt32, _ data: Data) -> Data {
        let start = Int(offset % 8)
        let o = UInt8(truncatingIfNeeded: offset)
        var out = [UInt8](repeating: 0, count: data.count)
        var i = 0
        for b in data {
            out[i] = b ^ xorKey[(start + i) % 8] ^ o
            i += 1
        }
        return Data(out)
    }

    /// Uppercase hex MD5 of a string (32 characters).
    public static func md5HexUpper(_ s: String) -> String {
        Insecure.MD5.hash(data: Data(s.utf8)).map { String(format: "%02X", $0) }.joined()
    }

    /// The camera's "truncated" MD5: uppercase hex with the last character dropped (31 chars),
    /// mimicking a 32-byte buffer that keeps a NUL terminator.
    public static func truncatedMD5(_ s: String) -> String {
        String(md5HexUpper(s).prefix(31))
    }

    /// AES key: the first 16 characters of the uppercase hex MD5 of "nonce-password".
    public static func aesKey(nonce: String, password: String) -> [UInt8] {
        Array(md5HexUpper("\(nonce)-\(password)").utf8.prefix(16))
    }

    // MARK: AES-128 CFB (128-bit segments), built on AES-ECB from CommonCrypto.

    static func aesEncryptBlock(key: [UInt8], _ block: [UInt8]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 16)
        var moved = 0
        let status = key.withUnsafeBytes { k in
            block.withUnsafeBytes { b in
                CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES128), CCOptions(kCCOptionECBMode),
                        k.baseAddress, 16, nil, b.baseAddress, 16, &out, 16, &moved)
            }
        }
        precondition(status == kCCSuccess && moved == 16, "AES block encryption failed")
        return out
    }

    public static func cfbEncrypt(key: [UInt8], iv: [UInt8] = aesIV, _ data: Data) -> Data {
        var register = iv
        var out = [UInt8](repeating: 0, count: data.count)
        let input = [UInt8](data)
        var pos = 0
        while pos < input.count {
            let stream = aesEncryptBlock(key: key, register)
            let n = min(16, input.count - pos)
            for i in 0..<n { out[pos + i] = input[pos + i] ^ stream[i] }
            if n == 16 { register = Array(out[pos..<(pos + 16)]) }
            pos += n
        }
        return Data(out)
    }

    public static func cfbDecrypt(key: [UInt8], iv: [UInt8] = aesIV, _ data: Data) -> Data {
        var register = iv
        var out = [UInt8](repeating: 0, count: data.count)
        let input = [UInt8](data)
        var pos = 0
        while pos < input.count {
            let stream = aesEncryptBlock(key: key, register)
            let n = min(16, input.count - pos)
            for i in 0..<n { out[pos + i] = input[pos + i] ^ stream[i] }
            if n == 16 { register = Array(input[pos..<(pos + 16)]) }
            pos += n
        }
        return Data(out)
    }
}
