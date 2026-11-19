import AVFoundation
import Baichuan
import CoreMedia
import Foundation

/// Turns the camera's ADTS-framed AAC into sample buffers that carry the compressed audio
/// unchanged. Used from one task at a time.
public final class AudioSampleBuilder {
    /// Every AAC frame holds this many PCM samples per channel.
    public static let samplesPerFrame = 1024

    private var configuration: Data?
    private var channels = 1
    /// One encoded frame of silence in the current format; `Data()` when it cannot be made.
    private var silence: Data?
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
        return sampleBuffer(payload: Data(header.payload(of: frame)), format: format, presentationTime: presentationTime)
    }

    /// A frame of silence in the format of the last frame seen, for filling a hole in the
    /// audio: an MP4 audio track has no gaps, so without filling, everything after the hole
    /// would play early. Returns nil before the first frame, or when the Mac cannot encode it.
    public func silentSampleBuffer(presentationTime: CMTime) -> CMSampleBuffer? {
        guard let format = formatDescription else { return nil }
        if silence == nil { silence = Self.encodeSilence(sampleRate: sampleRate, channels: channels) ?? Data() }
        guard let silence, !silence.isEmpty else { return nil }
        return sampleBuffer(payload: silence, format: format, presentationTime: presentationTime)
    }

    private func sampleBuffer(payload: Data, format: CMAudioFormatDescription, presentationTime: CMTime) -> CMSampleBuffer? {
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
        channels = header.channels
        silence = nil
        formatDescription = fd
        sampleRate = header.sampleRate
        return true
    }

    /// Encodes digital silence as AAC-LC and returns one frame from the steady state.
    static func encodeSilence(sampleRate: Double, channels: Int) -> Data? {
        var asbd = AudioStreamBasicDescription(mSampleRate: sampleRate, mFormatID: kAudioFormatMPEG4AAC, mFormatFlags: 0,
                                               mBytesPerPacket: 0, mFramesPerPacket: UInt32(samplesPerFrame), mBytesPerFrame: 0,
                                               mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 0, mReserved: 0)
        guard let pcmFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: AVAudioChannelCount(channels)),
              let aacFormat = AVAudioFormat(streamDescription: &asbd),
              let converter = AVAudioConverter(from: pcmFormat, to: aacFormat) else { return nil }
        var last: Data?
        for _ in 0..<8 {
            let output = AVAudioCompressedBuffer(format: aacFormat, packetCapacity: 1, maximumPacketSize: converter.maximumOutputPacketSize)
            var handedOver = false
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, outStatus in
                guard !handedOver, let pcm = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: AVAudioFrameCount(samplesPerFrame)) else {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                handedOver = true
                pcm.frameLength = AVAudioFrameCount(samplesPerFrame)  // a new buffer is zeroed: silence
                outStatus.pointee = .haveData
                return pcm
            }
            guard status != .error else { return nil }
            if output.byteLength > 0 { last = Data(bytes: output.data, count: Int(output.byteLength)) }
        }
        return last
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
