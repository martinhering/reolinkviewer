import Foundation

/// Errors raised by the Baichuan client.
public enum BCError: Error, CustomStringConvertible {
    case connectionFailed(String)
    case connectionClosed
    case timeout
    case invalidMagic(UInt32)
    case malformedHeader
    case malformedBody(String)
    case malformedXML(String)
    case unexpectedReply(msgId: UInt32, code: UInt16, why: String)
    case loginFailed(code: UInt16)
    case unknownEncryption(UInt8)
    case notConnected
    case mediaSyncLost(UInt32)

    public var description: String {
        switch self {
        case .connectionFailed(let s): return "connection failed: \(s)"
        case .connectionClosed: return "connection closed"
        case .timeout: return "timed out waiting for the camera"
        case .invalidMagic(let m): return String(format: "invalid packet magic 0x%08x", m)
        case .malformedHeader: return "malformed packet header"
        case .malformedBody(let s): return "malformed packet body: \(s)"
        case .malformedXML(let s): return "malformed XML: \(s)"
        case .unexpectedReply(let id, let code, let why): return "unexpected reply to message \(id) (code \(code)): \(why)"
        case .loginFailed(let code): return "login failed (code \(code)); check username and password"
        case .unknownEncryption(let b): return String(format: "camera requested unknown encryption 0x%02x", b)
        case .notConnected: return "not connected"
        case .mediaSyncLost(let m): return String(format: "lost sync in media stream (magic 0x%08x)", m)
        }
    }
}
