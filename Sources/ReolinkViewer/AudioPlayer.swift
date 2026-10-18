import AVFoundation
import Baichuan
import Foundation

/// Decodes the camera's AAC frames and plays them through the default output.
/// Fed from the stream task; `setEnabled` may be called from any thread.
final class AudioPlayer: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let lock = NSLock()
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    private var pcmFormat: AVAudioFormat?
    private var scheduledFrames: AVAudioFramePosition = 0
    private var enabled = true

    private(set) var decodedFrames = 0
    private(set) var peak: Float = 0

    /// Audio queued ahead of playback beyond this is dropped so live sound stays live.
    private let maxBacklog: TimeInterval = 1.0

    init() {
        engine.attach(player)
    }

    var statusDescription: String {
        lock.lock(); defer { lock.unlock() }
        let fmt = inputFormat.map { "\(Int($0.sampleRate)) Hz \($0.channelCount)ch" } ?? "no format"
        return String(format: "audio: %@ frames=%d peak=%.3f %@", enabled ? "on" : "muted", decodedFrames, peak, fmt)
    }

    func setEnabled(_ on: Bool) {
        lock.lock(); defer { lock.unlock() }
        enabled = on
        if !on { flushLocked() }
    }

    /// Call when a new stream starts: drops anything queued.
    func reset() {
        lock.lock(); defer { lock.unlock() }
        flushLocked()
        converter?.reset()
        peak = 0
    }

    func enqueue(adts frame: Data) {
        lock.lock(); defer { lock.unlock() }
        guard enabled, let header = ADTSHeader(parsing: frame) else { return }
        if inputFormat == nil || inputFormat!.sampleRate != header.sampleRate
            || inputFormat!.channelCount != AVAudioChannelCount(header.channels) {
            configure(header)
        }
        guard let converter, let inputFormat, let pcmFormat else { return }

        let payload = header.payload(of: frame)
        guard !payload.isEmpty else { return }
        let compressed = AVAudioCompressedBuffer(format: inputFormat, packetCapacity: 1, maximumPacketSize: payload.count)
        payload.withUnsafeBytes { raw in
            compressed.data.copyMemory(from: raw.baseAddress!, byteCount: payload.count)
        }
        compressed.byteLength = UInt32(payload.count)
        compressed.packetCount = 1
        compressed.packetDescriptions?.pointee = AudioStreamPacketDescription(
            mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(payload.count))

        guard let pcm = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: 4096) else { return }
        var handedOver = false
        var error: NSError?
        let status = converter.convert(to: pcm, error: &error) { _, outStatus in
            if handedOver {
                outStatus.pointee = .noDataNow
                return nil
            }
            handedOver = true
            outStatus.pointee = .haveData
            return compressed
        }
        guard status != .error, pcm.frameLength > 0 else {
            if let error { NSLog("audio decode failed: %@", error.localizedDescription) }
            return
        }

        if let channel = pcm.floatChannelData?.pointee {
            var p: Float = 0
            for i in 0..<Int(pcm.frameLength) { p = max(p, abs(channel[i])) }
            peak = max(peak, p)
        }
        decodedFrames += 1

        if !engine.isRunning {
            do { try engine.start() } catch { NSLog("audio engine failed to start: %@", "\(error)"); return }
        }
        if let nodeTime = player.lastRenderTime, let playerTime = player.playerTime(forNodeTime: nodeTime) {
            let backlog = Double(scheduledFrames - playerTime.sampleTime) / pcmFormat.sampleRate
            if backlog > maxBacklog { flushLocked() }
        }
        player.scheduleBuffer(pcm)
        scheduledFrames += AVAudioFramePosition(pcm.frameLength)
        if !player.isPlaying { player.play() }
    }

    private func configure(_ header: ADTSHeader) {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: header.sampleRate, mFormatID: kAudioFormatMPEG4AAC, mFormatFlags: 0, mBytesPerPacket: 0,
            mFramesPerPacket: 1024, mBytesPerFrame: 0, mChannelsPerFrame: UInt32(header.channels), mBitsPerChannel: 0,
            mReserved: 0)
        guard let input = AVAudioFormat(streamDescription: &asbd),
              let output = AVAudioFormat(standardFormatWithSampleRate: header.sampleRate,
                                         channels: AVAudioChannelCount(header.channels)),
              let conv = AVAudioConverter(from: input, to: output) else {
            NSLog("audio: unsupported format %@", "\(header)")
            return
        }
        conv.magicCookie = header.audioSpecificConfig
        flushLocked()
        engine.disconnectNodeOutput(player)
        engine.connect(player, to: engine.mainMixerNode, format: output)
        converter = conv
        inputFormat = input
        pcmFormat = output
    }

    private func flushLocked() {
        player.stop()
        scheduledFrames = 0
    }
}
