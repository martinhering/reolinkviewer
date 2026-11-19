import Baichuan
import CoreMedia
import Foundation

/// Turns the camera's ADTS-framed AAC into sample buffers that carry the compressed audio
/// unchanged. Used from one task at a time.
public final class AudioSampleBuilder {
    /// Every AAC frame holds this many PCM samples per channel.
    public static let samplesPerFrame = 1024

    private var configuration: Data?
    public private(set) var formatDescription: CMAudioFormatDescription?
    public private(set) var sampleRate: Double = 0

    public init() {}

    public func reset() {
        configuration = nil
        formatDescription = nil
        sampleRate = 0
    }

    /// Reads the format from an ADTS frame without producing a sample. Returns false when the
    /// frame is not ADTS or the format cannot be described.
    @discardableResult
    public func noteFormat(adts frame: Data) -> Bool {
        guard let header = ADTSHeader(parsing: frame) else { return false }
        return configure(header)
    }

    /// One AAC frame as a sample buffer starting at `presentationTime`.
    public func sampleBuffer(adts frame: Data, presentationTime: CMTime) -> CMSampleBuffer? {
        guard let header = ADTSHeader(parsing: frame), configure(header), let format = formatDescription else { return nil }
        let payload = Data(header.payload(of: frame))
        guard let block = makeBlockBuffer(payload) else { return nil }
        var packet = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(payload.count))
        var sample: CMSampleBuffer?
        let status = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format, sampleCount: 1,
            presentationTimeStamp: presentationTime, packetDescriptions: &packet, sampleBufferOut: &sample)
        return status == noErr ? sample : nil
    }

    private func configure(_ header: ADTSHeader) -> Bool {
        let config = header.audioSpecificConfig
        if config == configuration, formatDescription != nil { return true }
        var asbd = AudioStreamBasicDescription(
            mSampleRate: header.sampleRate, mFormatID: kAudioFormatMPEG4AAC, mFormatFlags: UInt32(header.audioObjectType),
            mBytesPerPacket: 0, mFramesPerPacket: UInt32(Self.samplesPerFrame), mBytesPerFrame: 0,
            mChannelsPerFrame: UInt32(header.channels), mBitsPerChannel: 0, mReserved: 0)
        let cookie = Self.elementaryStreamDescriptor(audioSpecificConfig: config)
        var fd: CMAudioFormatDescription?
        let status = cookie.withUnsafeBytes { raw in
            CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil,
                                           magicCookieSize: raw.count, magicCookie: raw.baseAddress, extensions: nil,
                                           formatDescriptionOut: &fd)
        }
        guard status == noErr, let fd else {
            NSLog("audio format description failed: \(status)")
            return false
        }
        configuration = config
        formatDescription = fd
        sampleRate = header.sampleRate
        return true
    }

    /// The MPEG-4 ES_Descriptor that MP4 files store in their `esds` box, which is what
    /// CoreMedia expects as the magic cookie of AAC.
    static func elementaryStreamDescriptor(audioSpecificConfig config: Data) -> Data {
        func descriptor(_ tag: UInt8, _ body: [UInt8]) -> [UInt8] {
            precondition(body.count < 128)
            return [tag, UInt8(body.count)] + body
        }
        let decoderSpecific = descriptor(0x05, [UInt8](config))
        // objectTypeIndication 0x40 = MPEG-4 audio, streamType 5 (audio) << 2 | 1,
        // then bufferSizeDB (3 bytes), maxBitrate and avgBitrate, all left at 0.
        let decoderConfig = descriptor(0x04, [0x40, 0x15, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0] + decoderSpecific)
        let slConfig = descriptor(0x06, [0x02])
        // ES_ID 0, no flags.
        return Data(descriptor(0x03, [0, 0, 0] + decoderConfig + slConfig))
    }
}
