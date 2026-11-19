import AVFoundation
import Baichuan
import CoreMedia
import Foundation

public enum RecordingError: Error, CustomStringConvertible {
    case cannotCreateWriter(String)
    case writerFailed(String)
    case writerStalled

    public var description: String {
        switch self {
        case .cannotCreateWriter(let why): return "cannot create the MP4 writer: \(why)"
        case .writerFailed(let why): return "writing the MP4 file failed: \(why)"
        case .writerStalled: return "the MP4 writer accepted no data for 2 s"
        }
    }
}

/// Writes a camera's stream into consecutive MP4 files without re-encoding.
///
/// Files are cut on the wall clock: the first key frame at or after each multiple of
/// `segmentLength` closes the running file and opens the next one, so every camera cuts at
/// the same moments and each file starts with a key frame. They are named
/// `<directory>/yyyy-MM-dd/HHmmssZ_<length>s.mp4` after their start time in UTC.
///
/// Feed it every frame of one stream in order, from one task.
public final class SegmentRecorder {
    /// A finished file.
    public struct Segment: Sendable {
        public let url: URL
        /// Wall-clock time of the first frame.
        public let start: Date
        public let duration: TimeInterval
        public let codec: VideoCodec
        public let width: Int
        public let height: Int
        public let videoFrames: Int
        public let keyFrames: Int
        public let audioFrames: Int
        /// Size of the file on disk.
        public let bytes: Int
    }

    private let directory: URL
    private let segmentLength: TimeInterval
    private let recordAudio: Bool
    private let now: () -> Date

    private let video = VideoSampleBuilder()
    private let audio = AudioSampleBuilder()

    // Stream time in microseconds. The camera's counter is 32 bits wide and wraps after
    // 71 minutes; this one does not.
    private var lastMicros: UInt32?
    private var streamTime: Int64 = 0
    private var frameDuration: Int64 = 40_000
    /// A wall-clock time and the stream time that belongs to it.
    private var anchor: (wall: Date, time: Int64)?
    private var firstVideoAt: Date?
    /// Presentation time of the next audio frame, in samples.
    private var nextAudioSample: Int64?
    private var current: OpenSegment?

    /// Time stamps that jumped backwards or more than 10 s ahead.
    public private(set) var discontinuities = 0

    /// How long to hold back the first file while no audio frame has arrived, so that it gets
    /// an audio track.
    static let audioWait: TimeInterval = 3

    /// - Parameters:
    ///   - segmentLength: seconds per file; cuts fall on multiples of it since 1970 (so 60
    ///     cuts on the minute).
    ///   - now: the wall clock, replaceable for tests.
    public init(directory: URL, segmentLength: TimeInterval = 60, recordAudio: Bool = true, now: @escaping () -> Date = { Date() }) {
        self.directory = directory
        self.segmentLength = max(1, segmentLength)
        self.recordAudio = recordAudio
        self.now = now
    }

    /// Adds a frame. Returns the file that this frame closed, if it closed one.
    @discardableResult
    public func append(_ frame: BCMediaFrame) async throws -> Segment? {
        switch frame {
        case .videoKeyFrame(let codec, let data, let micros, _):
            return try await appendVideo(codec: codec, data: data, micros: micros, isKeyFrame: true)
        case .videoFrame(let codec, let data, let micros):
            return try await appendVideo(codec: codec, data: data, micros: micros, isKeyFrame: false)
        case .aac(let data):
            if recordAudio { try await appendAudio(data) }
            return nil
        case .info, .adpcm:
            return nil
        }
    }

    /// Closes the running file. The recorder can be fed again afterwards and then starts a new
    /// file at the next key frame.
    @discardableResult
    public func finish() async throws -> Segment? {
        guard let segment = current else { return nil }
        current = nil
        return try await segment.finish(at: streamTime + frameDuration)
    }

    // MARK: Video

    private func appendVideo(codec: VideoCodec, data: Data, micros: UInt32, isKeyFrame: Bool) async throws -> Segment? {
        advanceStreamTime(to: micros)
        let wall = wallClock(for: streamTime)
        if firstVideoAt == nil { firstVideoAt = wall }
        guard let unit = video.accessUnit(codec: codec, data: data, isKeyFrame: isKeyFrame) else { return nil }

        var closed: Segment? = nil
        if let segment = current, unit.isKeyFrame, slot(of: wall) != segment.slot || unit.formatChanged {
            current = nil
            closed = try await segment.finish(at: streamTime)
        }
        if current == nil {
            guard unit.isKeyFrame else { return closed }
            // Without an audio format there is no audio track; give the first frames a moment to arrive.
            if recordAudio, audio.formatDescription == nil, let first = firstVideoAt,
               wall.timeIntervalSince(first) < Self.audioWait {
                return closed
            }
            current = try OpenSegment(url: url(for: wall), start: wall, slot: slot(of: wall), startTime: streamTime, codec: codec,
                                      video: unit.format, audio: recordAudio ? audio.formatDescription : nil)
        }
        guard let segment = current,
              let sample = VideoSampleBuilder.sampleBuffer(unit, presentationTime: CMTime(value: streamTime, timescale: 1_000_000)) else {
            return closed
        }
        try await segment.append(video: sample, isKeyFrame: unit.isKeyFrame)
        return closed
    }

    private func advanceStreamTime(to micros: UInt32) {
        defer { lastMicros = micros }
        guard let last = lastMicros else { return }
        let delta = Int64(Int32(bitPattern: micros &- last))
        if delta > 0 && delta <= 10_000_000 {
            streamTime += delta
            frameDuration = delta
        } else {
            discontinuities += 1
            streamTime += frameDuration
        }
    }

    /// The wall-clock time of a stream time. Follows the stream's own clock, which is steadier
    /// than arrival times, and re-anchors when the two drift more than 2 s apart.
    private func wallClock(for time: Int64) -> Date {
        let present = now()
        if let anchor {
            let estimate = anchor.wall.addingTimeInterval(Double(time - anchor.time) / 1_000_000)
            if abs(estimate.timeIntervalSince(present)) <= 2 { return estimate }
        }
        anchor = (present, time)
        return present
    }

    private func slot(of wall: Date) -> Int64 {
        Int64((wall.timeIntervalSince1970 / segmentLength).rounded(.down))
    }

    private func url(for wall: Date) -> URL {
        let day = DateFormatter()
        day.calendar = Calendar(identifier: .gregorian)
        day.locale = Locale(identifier: "en_US_POSIX")
        day.timeZone = TimeZone(identifier: "UTC")
        day.dateFormat = "yyyy-MM-dd"
        let folder = directory.appendingPathComponent(day.string(from: wall), isDirectory: true)
        day.dateFormat = "HHmmss'Z'"
        return folder.appendingPathComponent("\(day.string(from: wall))_\(Int(segmentLength))s.mp4")
    }

    // MARK: Audio

    private func appendAudio(_ adts: Data) async throws {
        // Audio frames carry no time stamp. They follow each other without gaps, so count
        // samples, starting from the video time at which the first one arrived.
        guard lastMicros != nil, let segment = current, segment.audioFormat != nil else {
            audio.noteFormat(adts: adts)
            nextAudioSample = nil
            return
        }
        guard audio.noteFormat(adts: adts) else { return }
        let rate = audio.sampleRate
        let videoSample = Int64((Double(streamTime) / 1_000_000 * rate).rounded())
        var position = nextAudioSample ?? videoSample
        // Lost frames or a restarted stream: line up with the video again.
        if abs(position - videoSample) > Int64(rate / 2) { position = videoSample }
        nextAudioSample = position + Int64(AudioSampleBuilder.samplesPerFrame)
        guard let format = audio.formatDescription, CFEqual(format, segment.audioFormat),
              let sample = audio.sampleBuffer(adts: adts, presentationTime: CMTime(value: position, timescale: CMTimeScale(rate))) else {
            return  // the format changed; the next file picks it up
        }
        try await segment.append(audio: sample)
    }
}

/// One MP4 file being written.
private final class OpenSegment {
    let url: URL
    let start: Date
    let slot: Int64
    let startTime: Int64
    let codec: VideoCodec
    let audioFormat: CMAudioFormatDescription?
    private let size: CMVideoDimensions
    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let audioInput: AVAssetWriterInput?
    private var videoFrames = 0
    private var keyFrames = 0
    private var audioFrames = 0

    init(url: URL, start: Date, slot: Int64, startTime: Int64, codec: VideoCodec,
         video: CMVideoFormatDescription, audio: CMAudioFormatDescription?) throws {
        self.url = url
        self.start = start
        self.slot = slot
        self.startTime = startTime
        self.codec = codec
        self.size = CMVideoFormatDescriptionGetDimensions(video)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: url)
            writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        } catch {
            throw RecordingError.cannotCreateWriter(error.localizedDescription)
        }
        // The index goes to the front of the file, so playback can start before the download ends.
        writer.shouldOptimizeForNetworkUse = true

        // No output settings: the samples are written as they are.
        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: video)
        videoInput.expectsMediaDataInRealTime = true
        guard writer.canAdd(videoInput) else { throw RecordingError.cannotCreateWriter("the video format is not accepted") }
        writer.add(videoInput)

        var audioInput: AVAssetWriterInput? = nil
        if let audio {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: audio)
            input.expectsMediaDataInRealTime = true
            if writer.canAdd(input) {
                writer.add(input)
                audioInput = input
            }
        }
        self.audioInput = audioInput
        self.audioFormat = audioInput == nil ? nil : audio

        guard writer.startWriting() else {
            throw RecordingError.cannotCreateWriter(writer.error?.localizedDescription ?? "unknown error")
        }
        writer.startSession(atSourceTime: CMTime(value: startTime, timescale: 1_000_000))
    }

    func append(video sample: CMSampleBuffer, isKeyFrame: Bool) async throws {
        try await append(sample, to: videoInput)
        videoFrames += 1
        if isKeyFrame { keyFrames += 1 }
    }

    func append(audio sample: CMSampleBuffer) async throws {
        guard let audioInput else { return }
        try await append(sample, to: audioInput)
        audioFrames += 1
    }

    private func append(_ sample: CMSampleBuffer, to input: AVAssetWriterInput) async throws {
        // Dropping a frame would break the picture until the next key frame, so wait instead.
        var waited = 0
        while !input.isReadyForMoreMediaData {
            guard writer.status == .writing else { break }
            guard waited < 400 else { throw RecordingError.writerStalled }
            try? await Task.sleep(for: .milliseconds(5))
            waited += 1
        }
        guard input.append(sample) else {
            throw RecordingError.writerFailed(writer.error?.localizedDescription ?? "sample rejected")
        }
    }

    /// Closes the file. `end` is the stream time at which the last frame stops being shown.
    func finish(at end: Int64) async throws -> SegmentRecorder.Segment {
        videoInput.markAsFinished()
        audioInput?.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: max(end, startTime), timescale: 1_000_000))
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw RecordingError.writerFailed(writer.error?.localizedDescription ?? "status \(writer.status.rawValue)")
        }
        let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
        return SegmentRecorder.Segment(url: url, start: start, duration: Double(max(end, startTime) - startTime) / 1_000_000,
                                       codec: codec, width: Int(size.width), height: Int(size.height),
                                       videoFrames: videoFrames, keyFrames: keyFrames, audioFrames: audioFrames, bytes: bytes)
    }
}
