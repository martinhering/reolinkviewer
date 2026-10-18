import Foundation

public enum VideoCodec: String, Sendable {
    case h264 = "H264"
    case h265 = "H265"
}

/// One item of the camera's media container, as carried in the binary payload of video messages.
public enum BCMediaFrame: Sendable {
    /// Stream header: resolution and nominal frame rate.
    case info(width: Int, height: Int, fps: Int)
    /// Key frame. `data` is an Annex B byte stream (parameter sets + IDR slice).
    case videoKeyFrame(codec: VideoCodec, data: Data, microseconds: UInt32, time: UInt32?)
    /// Predicted frame, Annex B.
    case videoFrame(codec: VideoCodec, data: Data, microseconds: UInt32)
    /// AAC audio with ADTS header.
    case aac(Data)
    /// DVI-4 ADPCM audio block (first 4 bytes are predictor state), 8 kHz.
    case adpcm(Data)
}

/// Incremental parser for the media container. Feed it the binary payloads in order.
public struct BCMediaParser: Sendable {
    static let magicInfoV1: UInt32 = 0x3130_3031
    static let magicInfoV2: UInt32 = 0x3230_3031
    static let magicIFrameFirst: UInt32 = 0x6364_3030
    static let magicIFrameLast: UInt32 = 0x6364_3039
    static let magicPFrameFirst: UInt32 = 0x6364_3130
    static let magicPFrameLast: UInt32 = 0x6364_3139
    static let magicAAC: UInt32 = 0x6277_3530
    static let magicADPCM: UInt32 = 0x6277_3130
    static let magicADPCMData: UInt16 = 0x0100
    static let pad = 8

    private var buffer: [UInt8] = []
    private var offset = 0
    public private(set) var resyncCount = 0

    public init() {}

    public mutating func append(_ data: Data) {
        if offset > 0 && offset == buffer.count {
            buffer.removeAll(keepingCapacity: true)
            offset = 0
        } else if offset > 1 << 20 {
            buffer.removeFirst(offset)
            offset = 0
        }
        buffer.append(contentsOf: data)
    }

    public mutating func reset() {
        buffer.removeAll(keepingCapacity: true)
        offset = 0
    }

    private static func padded(_ n: Int) -> Int {
        n % pad == 0 ? 0 : pad - n % pad
    }

    /// Returns the next complete frame, or nil if more data is needed.
    public mutating func next() throws -> BCMediaFrame? {
        while true {
            let available = buffer.count - offset
            guard available >= 4 else { return nil }
            var r = ByteReader(buffer, offset: offset)
            let magic = try r.u32()
            do {
                switch magic {
                case Self.magicInfoV1, Self.magicInfoV2:
                    guard available >= 32 else { return nil }
                    let headerSize = try r.u32()
                    guard headerSize == 32 else { throw BCError.mediaSyncLost(magic) }
                    let width = try r.u32()
                    let height = try r.u32()
                    _ = try r.u8()
                    let fps = try r.u8()
                    offset += 32
                    return .info(width: Int(width), height: Int(height), fps: Int(fps))

                case Self.magicIFrameFirst...Self.magicIFrameLast, Self.magicPFrameFirst...Self.magicPFrameLast:
                    guard available >= 24 else { return nil }
                    let typeBytes = try r.take(4)
                    guard let codec = VideoCodec(rawValue: String(decoding: typeBytes, as: UTF8.self)) else {
                        throw BCError.mediaSyncLost(magic)
                    }
                    let payloadSize = Int(try r.u32())
                    let extraHeader = Int(try r.u32())
                    let micros = try r.u32()
                    _ = try r.u32()
                    guard payloadSize < 16 << 20, extraHeader < 1 << 16 else { throw BCError.mediaSyncLost(magic) }
                    let total = 24 + extraHeader + payloadSize + Self.padded(payloadSize)
                    guard available >= total else { return nil }
                    var time: UInt32? = nil
                    let isKey = magic <= Self.magicIFrameLast
                    if isKey && extraHeader >= 4 {
                        time = try r.u32()
                        try r.skip(extraHeader - 4)
                    } else {
                        try r.skip(extraHeader)
                    }
                    let data = Data(try r.take(payloadSize))
                    offset += total
                    if isKey {
                        return .videoKeyFrame(codec: codec, data: data, microseconds: micros, time: time)
                    }
                    return .videoFrame(codec: codec, data: data, microseconds: micros)

                case Self.magicAAC:
                    guard available >= 8 else { return nil }
                    let size = Int(try r.u16())
                    _ = try r.u16()
                    let total = 8 + size + Self.padded(size)
                    guard available >= total else { return nil }
                    let data = Data(try r.take(size))
                    offset += total
                    return .aac(data)

                case Self.magicADPCM:
                    guard available >= 12 else { return nil }
                    let size = Int(try r.u16())
                    _ = try r.u16()
                    let dataMagic = try r.u16()
                    guard dataMagic == Self.magicADPCMData, size >= 4 else { throw BCError.mediaSyncLost(magic) }
                    _ = try r.u16()
                    let total = 8 + size + Self.padded(size)
                    guard available >= total else { return nil }
                    let data = Data(try r.take(size - 4))
                    offset += total
                    return .adpcm(data)

                default:
                    throw BCError.mediaSyncLost(magic)
                }
            } catch BCError.mediaSyncLost {
                // Drop everything buffered and wait for a message that starts with a known magic.
                resyncCount += 1
                buffer.removeAll(keepingCapacity: true)
                offset = 0
                return nil
            }
        }
    }
}
