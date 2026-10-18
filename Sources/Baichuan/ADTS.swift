import Foundation

/// The 7- or 9-byte ADTS header that precedes each AAC frame the camera sends.
public struct ADTSHeader: Equatable, Sendable {
    public static let sampleRates: [Double] = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050,
                                               16000, 12000, 11025, 8000, 7350]

    public let isMPEG2: Bool
    public let hasCRC: Bool
    /// 0 = Main, 1 = LC, 2 = SSR, 3 = LTP. The MPEG-4 audio object type is `profile + 1`.
    public let profile: Int
    public let sampleRateIndex: Int
    public let channelConfiguration: Int
    /// Total frame length including this header.
    public let frameLength: Int

    public init?(parsing data: Data) {
        let b = [UInt8](data.prefix(7))
        guard b.count == 7, b[0] == 0xFF, (b[1] & 0xF0) == 0xF0 else { return nil }
        isMPEG2 = (b[1] & 0x08) != 0
        hasCRC = (b[1] & 0x01) == 0
        profile = Int(b[2] >> 6)
        sampleRateIndex = Int((b[2] >> 2) & 0x0F)
        channelConfiguration = Int(((b[2] & 0x01) << 2) | (b[3] >> 6))
        frameLength = (Int(b[3] & 0x03) << 11) | (Int(b[4]) << 3) | Int(b[5] >> 5)
        guard sampleRateIndex < Self.sampleRates.count, frameLength >= headerLength else { return nil }
    }

    public var headerLength: Int { hasCRC ? 9 : 7 }
    public var sampleRate: Double { Self.sampleRates[sampleRateIndex] }
    public var channels: Int { channelConfiguration == 7 ? 8 : max(channelConfiguration, 1) }
    public var audioObjectType: Int { profile + 1 }

    /// The two-byte AudioSpecificConfig decoders need ("magic cookie").
    public var audioSpecificConfig: Data {
        Data([UInt8((audioObjectType << 3) | (sampleRateIndex >> 1)),
              UInt8(((sampleRateIndex & 1) << 7) | (channelConfiguration << 3))])
    }

    /// The raw AAC access unit without the ADTS header.
    public func payload(of frame: Data) -> Data {
        frame.dropFirst(headerLength).prefix(frameLength - headerLength)
    }
}
