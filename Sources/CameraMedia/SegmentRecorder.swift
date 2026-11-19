import AVFoundation
import Baichuan
import CoreMedia
import Foundation

public enum RecordingError: Error, CustomStringConvertible {
    case cannotCreateWriter(String)
    case writerFailed(String)
    case writerStalled(String)

    public var description: String {
        switch self {
        case .cannotCreateWriter(let why): return "cannot create the MP4 writer: \(why)"
        case .writerFailed(let why): return "writing the MP4 file failed: \(why)"
        case .writerStalled(let what): return "the MP4 writer stopped accepting data at \(what)"
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
/// A file's frames are held in memory and written when it closes. A camera on a weak link
/// drops audio for seconds at a time, and a writer fed as the frames arrive then holds the
/// video back until the audio catches up, which it never does.
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
    /// Presentation time of the next audio frame, in samples.
    private var nextAudioSample: Int64?
    private var current: OpenSegment?
    /// Closed by an `append` that then threw, so it could not return them.
    private var unreported: [Segment] = []

    /// Time stamps that jumped backwards or more than 10 s ahead.
    public private(set) var discontinuities = 0

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
            if recordAudio { appendAudio(data) }
            return nil
        case .info, .adpcm:
            return nil
        }
    }

    /// Closes the running file. The recorder can be fed again afterwards and then starts a new
    /// file at the next key frame.
    ///
    /// Returns the files not reported yet: the running one and, after `append` threw, one it
    /// had just closed.
    @discardableResult
    public func finish() async throws -> [Segment] {
        var segments = unreported
        unreported = []
        if let segment = current {
            current = nil
            segments.append(try await segment.finish(at: streamTime + frameDuration))
        }
        return segments
    }

    // MARK: Video

    private func appendVideo(codec: VideoCodec, data: Data, micros: UInt32, isKeyFrame: Bool) async throws -> Segment? {
        advanceStreamTime(to: micros)
        let wall = wallClock(for: streamTime)
        guard let unit = video.accessUnit(codec: codec, data: data, isKeyFrame: isKeyFrame) else { return nil }

        var closed: Segment? = nil
        if let segment = current, unit.isKeyFrame, slot(of: wall) != segment.slot || unit.formatChanged {
            current = nil
            closed = try await segment.finish(at: streamTime)
        }
        do {
            try await write(unit, codec: codec, wall: wall)
        } catch {
            if let closed { unreported.append(closed) }
            throw error
        }
        return closed
    }

    /// Opens a file if none is running and this is a key frame, then writes the frame.
    private func write(_ unit: VideoSampleBuilder.AccessUnit, codec: VideoCodec, wall: Date) async throws {
        if current == nil {
            guard unit.isKeyFrame else { return }
            current = OpenSegment(url: url(for: wall), start: wall, slot: slot(of: wall), startTime: streamTime, codec: codec,
                                  video: unit.format)
        }
        guard let segment = current,
              let sample = VideoSampleBuilder.sampleBuffer(unit, presentationTime: CMTime(value: streamTime, timescale: 1_000_000)) else {
            return
        }
        segment.append(video: sample, isKeyFrame: unit.isKeyFrame)
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

    private func appendAudio(_ adts: Data) {
        // Audio frames carry no time stamp. They follow each other without gaps, so count
        // samples, starting from the video time at which the first one arrived.
        guard audio.noteFormat(adts: adts), lastMicros != nil, let segment = current else {
            nextAudioSample = nil
            return
        }
        let rate = audio.sampleRate
        let videoSample = Int64((Double(streamTime) / 1_000_000 * rate).rounded())
        var position = nextAudioSample ?? videoSample
        // Lost frames or a restarted stream: line up with the video again.
        if abs(position - videoSample) > Int64(rate / 2) {
            // An MP4 audio track has no gaps: fill the hole with silence, or the sound after
            // it would play early.
            let frame = Int64(AudioSampleBuilder.samplesPerFrame)
            var fill = max(position, Int64((Double(segment.startTime) / 1_000_000 * rate).rounded()))
            while segment.hasAudio, fill + frame <= videoSample,
                  let silent = audio.silentSampleBuffer(presentationTime: CMTime(value: fill, timescale: CMTimeScale(rate))) {
                segment.append(audio: silent)
                fill += frame
            }
            // After filling, the next frame follows the silence; otherwise it starts at the video's time.
            position = fill > position && fill <= videoSample ? fill : videoSample
        }
        nextAudioSample = position + Int64(AudioSampleBuilder.samplesPerFrame)
        if let sample = audio.sampleBuffer(adts: adts, presentationTime: CMTime(value: position, timescale: CMTimeScale(rate))) {
            segment.append(audio: sample)
        }
    }
}

/// One MP4 file: collects the frames, then writes them all when the file closes.
private final class OpenSegment {
    let url: URL
    let start: Date
    let slot: Int64
    let startTime: Int64
    let codec: VideoCodec
    private let videoFormat: CMVideoFormatDescription
    private var audioFormat: CMAudioFormatDescription?
    private var video: [CMSampleBuffer] = []
    private var audio: [CMSampleBuffer] = []
    private var keyFrames = 0

    init(url: URL, start: Date, slot: Int64, startTime: Int64, codec: VideoCodec, video: CMVideoFormatDescription) {
        self.url = url
        self.start = start
        self.slot = slot
        self.startTime = startTime
        self.codec = codec
        self.videoFormat = video
    }

    var hasAudio: Bool { !audio.isEmpty }

    func append(video sample: CMSampleBuffer, isKeyFrame: Bool) {
        video.append(sample)
        if isKeyFrame { keyFrames += 1 }
    }

    /// A file has one audio format: that of its first audio frame. Frames in another format
    /// are left out; the next file picks the new format up.
    func append(audio sample: CMSampleBuffer) {
        guard let format = CMSampleBufferGetFormatDescription(sample) else { return }
        if audioFormat == nil { audioFormat = format }
        if CFEqual(format, audioFormat) { audio.append(sample) }
    }

    /// Writes the file. `end` is the stream time at which the last frame stops being shown.
    func finish(at end: Int64) async throws -> SegmentRecorder.Segment {
        let writer: AVAssetWriter
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
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: videoFormat)
        guard writer.canAdd(videoInput) else { throw RecordingError.cannotCreateWriter("the video format is not accepted") }
        writer.add(videoInput)
        var audioInput: AVAssetWriterInput? = nil
        if let audioFormat, !audio.isEmpty {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: audioFormat)
            if writer.canAdd(input) {
                writer.add(input)
                audioInput = input
            }
        }
        if audioInput == nil { audio = [] }

        guard writer.startWriting() else {
            throw RecordingError.cannotCreateWriter(writer.error?.localizedDescription ?? "unknown error")
        }
        writer.startSession(atSourceTime: CMTime(value: startTime, timescale: 1_000_000))

        // Feed both tracks in time order. The writer interleaves them and at times refuses
        // one track until it has more of the other, so offer the other one then.
        var v = 0, a = 0, idle = 0
        while v < video.count || a < audio.count {
            let videoFirst = a >= audio.count || (v < video.count
                && CMSampleBufferGetPresentationTimeStamp(video[v]) <= CMSampleBufferGetPresentationTimeStamp(audio[a]))
            var appended = false
            for isVideo in [videoFirst, !videoFirst] where !appended {
                if isVideo, v < video.count, videoInput.isReadyForMoreMediaData {
                    guard videoInput.append(video[v]) else { throw failure(writer) }
                    v += 1
                    appended = true
                    if v == video.count { videoInput.markAsFinished() }
                } else if !isVideo, a < audio.count, let audioInput, audioInput.isReadyForMoreMediaData {
                    guard audioInput.append(audio[a]) else { throw failure(writer) }
                    a += 1
                    appended = true
                    if a == audio.count { audioInput.markAsFinished() }
                }
            }
            if appended {
                idle = 0
            } else {
                guard writer.status == .writing else { throw failure(writer) }
                guard idle < 2500 else {
                    writer.cancelWriting()
                    throw RecordingError.writerStalled("frame \(v) of \(video.count), audio frame \(a) of \(audio.count)")
                }
                idle += 1
                try? await Task.sleep(for: .milliseconds(2))
            }
        }
        if video.isEmpty { videoInput.markAsFinished() }

        let stop = max(end, startTime)
        writer.endSession(atSourceTime: CMTime(value: stop, timescale: 1_000_000))
        await writer.finishWriting()
        guard writer.status == .completed else { throw failure(writer) }
        let size = CMVideoFormatDescriptionGetDimensions(videoFormat)
        let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
        return SegmentRecorder.Segment(url: url, start: start, duration: Double(stop - startTime) / 1_000_000,
                                       codec: codec, width: Int(size.width), height: Int(size.height),
                                       videoFrames: video.count, keyFrames: keyFrames, audioFrames: audio.count, bytes: bytes)
    }

    private func failure(_ writer: AVAssetWriter) -> RecordingError {
        .writerFailed(writer.error?.localizedDescription ?? "status \(writer.status.rawValue)")
    }
}
