import Foundation

/// Serialises and parses packets, tracking the per-connection state the wire format needs:
/// the negotiated encryption and which message numbers are in binary (video) mode.
struct BCCodec {
    private(set) var encryption: BCEncryption = .unencrypted
    private var binaryMessageNumbers: Set<UInt16> = []
    let password: String

    init(password: String) {
        self.password = password
    }

    /// Login messages are never encrypted beyond BCEncrypt, even once AES is negotiated.
    private func encryptionFor(msgId: UInt32) -> BCEncryption {
        if msgId == BCMsgID.login && encryption.isAES { return .bcEncrypt }
        return encryption
    }

    func encode(_ m: BCMessage) -> Data {
        var body = Data()
        var payloadOffset: UInt32? = nil
        if m.msgClass != BCHeader.classLegacy {
            let enc = encryptionFor(msgId: m.msgId)
            var ext = Data()
            if let x = m.extensionXML {
                ext = enc.encrypt(offset: UInt32(m.channelId), Data(x.utf8))
            }
            var payload = Data()
            switch m.payload {
            case .xml(let s)?: payload = enc.encrypt(offset: UInt32(m.channelId), Data(s.utf8))
            case .binary(let d)?: payload = d
            case nil: break
            }
            body = ext + payload
            if BCHeader.classHasPayloadOffset(m.msgClass) {
                payloadOffset = m.extensionXML != nil ? UInt32(ext.count) : 0
            }
        }
        // Legacy "LoginUpgrade" is header-only.
        let header = BCHeader(msgId: m.msgId, bodyLength: UInt32(body.count), channelId: m.channelId,
                              streamType: m.streamType, msgNum: m.msgNum, responseCode: m.responseCode,
                              msgClass: m.msgClass, payloadOffset: payloadOffset)
        return header.encode() + body
    }

    mutating func decode(header h: BCHeader, body: Data) throws -> BCMessage {
        var m = BCMessage(msgId: h.msgId, channelId: h.channelId, streamType: h.streamType, msgNum: h.msgNum,
                          responseCode: h.responseCode, msgClass: h.msgClass)
        guard h.isModern else {
            if !body.isEmpty { m.payload = .binary(body) }
            return m
        }

        let extLen = Int(h.payloadOffset ?? 0)
        guard extLen <= body.count else { throw BCError.malformedBody("payload offset beyond body") }
        let extBytes = body.prefix(extLen)
        let payloadBytes = body.dropFirst(extLen)
        let channel = UInt32(h.channelId)

        var inBinary = false
        var encryptLen: Int? = nil
        if extLen > 0 {
            let plain = encryption.decrypt(offset: channel, Data(extBytes))
            let text = String(decoding: plain, as: UTF8.self)
            m.extensionXML = text
            if let ext = try? XMLReader(text) {
                let flag = ext.int("/Extension/binaryData")
                if flag == 1 {
                    inBinary = true
                    encryptLen = ext.int("/Extension/encryptLen")
                }
                if let flag {
                    if flag == 0 { binaryMessageNumbers.remove(h.msgNum) } else { binaryMessageNumbers.insert(h.msgNum) }
                }
            }
        }

        if !payloadBytes.isEmpty {
            let payloadEncryption: BCEncryption
            if h.msgId == BCMsgID.login, (h.responseCode >> 8) == 0xDD {
                // The nonce reply announces the encryption; it is itself at most BCEncrypt.
                payloadEncryption = (h.responseCode & 0xFF) == 0 ? .unencrypted : .bcEncrypt
            } else if h.msgId == BCMsgID.login, encryption.isAES {
                payloadEncryption = .bcEncrypt
            } else {
                payloadEncryption = encryption
            }

            if binaryMessageNumbers.contains(h.msgNum) || inBinary {
                if case .fullAes = encryption, let encryptLen {
                    let plain = payloadEncryption.decrypt(offset: channel, Data(payloadBytes))
                    m.payload = .binary(plain.prefix(encryptLen))
                } else {
                    m.payload = .binary(Data(payloadBytes))
                }
            } else {
                let plain = payloadEncryption.decrypt(offset: channel, Data(payloadBytes))
                m.payload = .xml(String(decoding: plain, as: UTF8.self))
            }
        }

        // The reply to the legacy login carries the nonce and fixes the encryption for the session.
        if h.msgId == BCMsgID.login, (h.responseCode >> 8) == 0xDD, let xml = m.xml,
           let reader = try? XMLReader(xml), let nonce = reader.string("/body/Encryption/nonce") {
            let mode = UInt8(h.responseCode & 0xFF)
            switch mode {
            case 0x00: encryption = .unencrypted
            case 0x01: encryption = .bcEncrypt
            case 0x02: encryption = .aes(key: BCCrypto.aesKey(nonce: nonce, password: password))
            case 0x12: encryption = .fullAes(key: BCCrypto.aesKey(nonce: nonce, password: password))
            default: throw BCError.unknownEncryption(mode)
            }
        }
        return m
    }
}
