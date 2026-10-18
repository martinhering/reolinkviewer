import Foundation

/// The fixed packet header of the Baichuan protocol. All integers are little-endian.
///
/// Layout (20 bytes, plus 4 for classes that carry a payload offset):
///   u32 magic (0x0abcdef0) · u32 msgId · u32 bodyLength · u8 channelId · u8 streamType
///   u16 msgNum · u16 responseCode · u16 class · [u32 payloadOffset]
public struct BCHeader: Equatable, Sendable {
    public static let magic: UInt32 = 0x0ABC_DEF0
    public static let magicReversed: UInt32 = 0x0FED_CBA0
    public static let baseLength = 20

    /// Legacy login class: 20-byte header, body is not XML.
    public static let classLegacy: UInt16 = 0x6514
    /// Reply to a legacy login: 20-byte header, modern (XML) body, no payload offset.
    public static let classLoginReply: UInt16 = 0x6614
    /// Standard modern class: 24-byte header with payload offset.
    public static let classModern: UInt16 = 0x6414

    public var msgId: UInt32
    public var bodyLength: UInt32
    public var channelId: UInt8
    public var streamType: UInt8
    public var msgNum: UInt16
    public var responseCode: UInt16
    public var msgClass: UInt16
    public var payloadOffset: UInt32?

    public static func classHasPayloadOffset(_ c: UInt16) -> Bool { c == 0x6414 || c == 0x0000 }

    public var isModern: Bool { msgClass != Self.classLegacy }
    public var length: Int { Self.classHasPayloadOffset(msgClass) ? 24 : 20 }

    public func encode() -> Data {
        var w = ByteWriter()
        w.u32(Self.magic)
        w.u32(msgId)
        w.u32(bodyLength)
        w.u8(channelId)
        w.u8(streamType)
        w.u16(msgNum)
        w.u16(responseCode)
        w.u16(msgClass)
        if Self.classHasPayloadOffset(msgClass) {
            w.u32(payloadOffset ?? 0)
        }
        return w.data
    }

    /// Decodes the first 20 bytes. If the class carries a payload offset the caller must
    /// read 4 more bytes and set `payloadOffset`.
    public static func decodeBase(_ data: Data) throws -> BCHeader {
        var r = ByteReader([UInt8](data))
        let magic = try r.u32()
        guard magic == Self.magic || magic == Self.magicReversed else { throw BCError.invalidMagic(magic) }
        let msgId = try r.u32()
        let bodyLength = try r.u32()
        let channelId = try r.u8()
        let streamType = try r.u8()
        let msgNum = try r.u16()
        let responseCode = try r.u16()
        let msgClass = try r.u16()
        return BCHeader(msgId: msgId, bodyLength: bodyLength, channelId: channelId, streamType: streamType,
                        msgNum: msgNum, responseCode: responseCode, msgClass: msgClass, payloadOffset: nil)
    }

    /// Decodes a complete header (20 or 24 bytes depending on class).
    public static func decode(_ data: Data) throws -> BCHeader {
        var h = try decodeBase(data)
        if Self.classHasPayloadOffset(h.msgClass) {
            guard data.count >= 24 else { throw BCError.malformedHeader }
            h.payloadOffset = data.le32(at: 20)
        }
        return h
    }
}
