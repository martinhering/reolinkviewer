import AVFoundation
import Baichuan
import CoreMedia
import XCTest
@testable import CameraMedia

final class AnnexBTests: XCTestCase {
    func testSplitsOnThreeAndFourByteStartCodes() {
        let stream = Data([0, 0, 0, 1, 0x67, 1, 2, 0, 0, 1, 0x68, 3, 0, 0, 0, 1, 0x65, 4, 5, 6])
        XCTAssertEqual(AnnexB.nalUnits(stream).map { [UInt8]($0) }, [[0x67, 1, 2], [0x68, 3], [0x65, 4, 5, 6]])
    }

    func testNoStartCodeMeansNoUnits() {
        XCTAssertTrue(AnnexB.nalUnits(Data([1, 2, 3, 4])).isEmpty)
    }
}

final class VideoSampleBuilderTests: XCTestCase {
    func testDropsFramesUntilTheFirstKeyFrame() throws {
        let frames = try TestStream.video(codec: .h264, count: 12)
        let builder = VideoSampleBuilder()
        XCTAssertNil(builder.accessUnit(codec: .h264, data: frames[1].data, isKeyFrame: false))
        let key = try XCTUnwrap(builder.accessUnit(codec: .h264, data: frames[0].data, isKeyFrame: true))
        XCTAssertTrue(key.isKeyFrame)
        XCTAssertFalse(key.formatChanged)
        XCTAssertEqual(builder.frameSize, CGSize(width: 320, height: 240))
        XCTAssertNotNil(builder.accessUnit(codec: .h264, data: frames[1].data, isKeyFrame: false))
        builder.requireKeyFrame()
        XCTAssertNil(builder.accessUnit(codec: .h264, data: frames[2].data, isKeyFrame: false))
        XCTAssertNotNil(builder.accessUnit(codec: .h264, data: frames[10].data, isKeyFrame: true))
    }

    func testReportsAChangedFormatOnce() throws {
        let small = try TestStream.video(codec: .h264, count: 2)
        let large = try TestStream.video(codec: .h264, count: 2, width: 640, height: 480)
        let builder = VideoSampleBuilder()
        XCTAssertEqual(builder.accessUnit(codec: .h264, data: small[0].data, isKeyFrame: true)?.formatChanged, false)
        XCTAssertEqual(builder.accessUnit(codec: .h264, data: large[0].data, isKeyFrame: true)?.formatChanged, true)
        XCTAssertEqual(builder.accessUnit(codec: .h264, data: large[1].data, isKeyFrame: false)?.formatChanged, false)
        XCTAssertEqual(builder.frameSize, CGSize(width: 640, height: 480))
    }
}

final class SegmentRecorderTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("SegmentRecorderTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// A wall clock the test moves by hand.
    private final class Clock: @unchecked Sendable {
        var date: Date
        init(_ date: Date) { self.date = date }
    }

    /// Feeds 25 fps video and, if given, the audio that belongs to the same time span.
    /// Returns the finished files in order.
    private func record(_ video: [TestStream.Frame], codec: VideoCodec, audio: [Data] = [], audioRate: Double = 16000,
                        start: Date, firstMicros: UInt32 = 5_000_000, segmentLength: TimeInterval,
                        recordAudio: Bool = true) async throws -> [SegmentRecorder.Segment] {
        let clock = Clock(start)
        let recorder = SegmentRecorder(directory: directory, segmentLength: segmentLength, recordAudio: recordAudio) { clock.date }
        var segments: [SegmentRecorder.Segment] = []
        var audioSent = 0
        for (i, frame) in video.enumerated() {
            let elapsed = Double(i) / 25
            clock.date = start.addingTimeInterval(elapsed)
            // Audio first, as the camera's first audio frame usually beats the first key frame.
            while audioSent < audio.count, Double(audioSent) * 1024 / audioRate <= elapsed {
                try await recorder.append(.aac(audio[audioSent]))
                audioSent += 1
            }
            let micros = firstMicros &+ UInt32(i * 40_000)
            let item: BCMediaFrame = frame.isKeyFrame
                ? .videoKeyFrame(codec: codec, data: frame.data, microseconds: micros, time: nil)
                : .videoFrame(codec: codec, data: frame.data, microseconds: micros)
            if let closed = try await recorder.append(item) { segments.append(closed) }
        }
        segments += try await recorder.finish()
        XCTAssertEqual(recorder.discontinuities, 0)
        return segments
    }

    /// Decodes every sample of a track and returns how many there were.
    private func decodedSampleCount(_ asset: AVURLAsset, _ type: AVMediaType) async throws -> Int {
        let tracks = try await asset.loadTracks(withMediaType: type)
        let track = try XCTUnwrap(tracks.first)
        let reader = try AVAssetReader(asset: asset)
        let settings: [String: Any] = type == .video
            ? [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            : [AVFormatIDKey: kAudioFormatLinearPCM]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        reader.add(output)
        XCTAssertTrue(reader.startReading(), "\(String(describing: reader.error))")
        var count = 0
        while let sample = output.copyNextSampleBuffer() {
            count += type == .video ? 1 : CMSampleBufferGetNumSamples(sample)
        }
        XCTAssertEqual(reader.status, .completed, "\(String(describing: reader.error))")
        return count
    }

    private func codecType(_ asset: AVURLAsset, _ type: AVMediaType) async throws -> FourCharCode {
        let tracks = try await asset.loadTracks(withMediaType: type)
        let formats = try await XCTUnwrap(tracks.first).load(.formatDescriptions)
        let format = try XCTUnwrap(formats.first)
        return CMFormatDescriptionGetMediaSubType(format)
    }

    // 2026-11-19 10:00:00 UTC, the start of a minute.
    private let tenOClock = Date(timeIntervalSince1970: 1_795_082_400)

    func testWritesAPlayableH264FileWithSound() async throws {
        let video = try TestStream.video(codec: .h264, count: 50)
        let audio = try TestStream.audio(frames: 31)  // 2 s at 16 kHz
        let segments = try await record(video, codec: .h264, audio: audio, start: tenOClock, segmentLength: 60)
        XCTAssertEqual(segments.count, 1)
        let segment = segments[0]
        XCTAssertEqual(segment.url.path, directory.appendingPathComponent("2026-11-19/100000Z_60s.mp4").path)
        XCTAssertEqual(segment.start, tenOClock)
        XCTAssertEqual(segment.videoFrames, 50)
        XCTAssertEqual(segment.keyFrames, 5)
        XCTAssertEqual(segment.duration, 2.0, accuracy: 0.001)
        XCTAssertEqual([segment.width, segment.height], [320, 240])
        XCTAssertGreaterThan(segment.audioFrames, 25)
        XCTAssertGreaterThan(segment.bytes, 0)

        let asset = AVURLAsset(url: segment.url)
        let duration = try await asset.load(.duration)
        XCTAssertEqual(duration.seconds, 2.0, accuracy: 0.05)
        let type = try await codecType(asset, .video)
        XCTAssertEqual(type, kCMVideoCodecType_H264)
        let audioType = try await codecType(asset, .audio)
        XCTAssertEqual(audioType, kAudioFormatMPEG4AAC)
        let pictures = try await decodedSampleCount(asset, .video)
        XCTAssertEqual(pictures, 50)
        let samples = try await decodedSampleCount(asset, .audio)
        XCTAssertGreaterThan(samples, 25 * 1024)
    }

    func testWritesAPlayableH265File() async throws {
        let video = try TestStream.video(codec: .h265, count: 30)
        let segments = try await record(video, codec: .h265, start: tenOClock, segmentLength: 60, recordAudio: false)
        XCTAssertEqual(segments.count, 1)
        let asset = AVURLAsset(url: segments[0].url)
        // QuickTime only plays HEVC stored as 'hvc1'.
        let type = try await codecType(asset, .video)
        XCTAssertEqual(type, kCMVideoCodecType_HEVC)
        let pictures = try await decodedSampleCount(asset, .video)
        XCTAssertEqual(pictures, 30)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertTrue(audioTracks.isEmpty)
    }

    func testCutsAtTheFirstKeyFrameAfterEachBoundary() async throws {
        // Key frames every 0.4 s, starting 0.3 s before a 2 s boundary: frames 0, 10, 20, …
        // arrive at -0.3, 0.1, 0.5, … so the cuts fall on frames 10 (0.1 s) and 60 (2.1 s).
        let video = try TestStream.video(codec: .h264, count: 75)
        let start = tenOClock.addingTimeInterval(-0.3)
        let segments = try await record(video, codec: .h264, start: start, segmentLength: 2, recordAudio: false)
        XCTAssertEqual(segments.map(\.videoFrames), [10, 50, 15])
        XCTAssertEqual(segments.map { $0.url.lastPathComponent }, ["095959Z_2s.mp4", "100000Z_2s.mp4", "100002Z_2s.mp4"])
        XCTAssertEqual(segments[1].start.timeIntervalSince(tenOClock), 0.1, accuracy: 0.001)
        XCTAssertEqual(segments[1].duration, 2.0, accuracy: 0.001)
        for segment in segments {
            let asset = AVURLAsset(url: segment.url)
            let pictures = try await decodedSampleCount(asset, .video)
            XCTAssertEqual(pictures, segment.videoFrames, segment.url.lastPathComponent)
        }
    }

    func testSurvivesTheCamerasTimeStampWrappingAround() async throws {
        let video = try TestStream.video(codec: .h264, count: 50)
        // The 32-bit microsecond counter wraps one second into the recording.
        let segments = try await record(video, codec: .h264, start: tenOClock, firstMicros: UInt32.max - 1_000_000,
                                        segmentLength: 60, recordAudio: false)
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].duration, 2.0, accuracy: 0.001)
        let duration = try await AVURLAsset(url: segments[0].url).load(.duration)
        XCTAssertEqual(duration.seconds, 2.0, accuracy: 0.05)
    }

    func testNoAudioTrackWhenTheCameraSendsNoSound() async throws {
        let video = try TestStream.video(codec: .h264, count: 50)
        let segments = try await record(video, codec: .h264, start: tenOClock, segmentLength: 60)
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].audioFrames, 0)
        XCTAssertEqual(segments[0].videoFrames, 50)
        let audioTracks = try await AVURLAsset(url: segments[0].url).loadTracks(withMediaType: .audio)
        XCTAssertTrue(audioTracks.isEmpty)
    }

    func testSurvivesSoundThatStopsWhileThePictureGoesOn() async throws {
        // A camera on a weak link: 20 s of video, but only the first second of audio arrives.
        let video = try TestStream.video(codec: .h264, count: 500)
        let audio = try TestStream.audio(frames: 16)
        let segments = try await record(video, codec: .h264, audio: audio, start: tenOClock, segmentLength: 60)
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].videoFrames, 500)
        XCTAssertEqual(segments[0].audioFrames, 15)  // the one before the first picture has no time yet
        let asset = AVURLAsset(url: segments[0].url)
        let pictures = try await decodedSampleCount(asset, .video)
        XCTAssertEqual(pictures, 500)
        let duration = try await asset.load(.duration)
        XCTAssertEqual(duration.seconds, 20.0, accuracy: 0.05)
    }

    func testSurvivesAHoleInTheSound() async throws {
        // Sound for 1 s, nothing for 18 s, then sound again: the audio clock lines up with the video.
        let video = try TestStream.video(codec: .h264, count: 500)
        let audio = try TestStream.audio(frames: 32)
        let clock = Clock(tenOClock)
        let recorder = SegmentRecorder(directory: directory, segmentLength: 60) { clock.date }
        var sent = 0
        for (i, frame) in video.enumerated() {
            let elapsed = Double(i) / 25
            clock.date = tenOClock.addingTimeInterval(elapsed)
            let micros = UInt32(5_000_000 + i * 40_000)
            try await recorder.append(frame.isKeyFrame ? .videoKeyFrame(codec: .h264, data: frame.data, microseconds: micros, time: nil)
                                                       : .videoFrame(codec: .h264, data: frame.data, microseconds: micros))
            let audible = elapsed < 1 || elapsed >= 19
            if audible, sent < audio.count, i % 2 == 0 {
                try await recorder.append(.aac(audio[sent]))
                sent += 1
            }
        }
        let segments = try await recorder.finish()
        XCTAssertEqual(segments.count, 1)
        // 18 s of silence at 64 ms a frame fill the hole.
        XCTAssertEqual(Double(segments[0].audioFrames - sent), 18 / 0.064, accuracy: 10)
        let asset = AVURLAsset(url: segments[0].url)
        let pictures = try await decodedSampleCount(asset, .video)
        XCTAssertEqual(pictures, 500)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        let range = try await XCTUnwrap(tracks.first).load(.timeRange)
        XCTAssertGreaterThan(range.end.seconds, 19, "the late sound sits at the end of the file, not right after the early sound")
    }
}

final class AudioSampleBuilderTests: XCTestCase {
    func testDescribesTheCamerasAAC() throws {
        let frame = TestStream.adts(Data(repeating: 0, count: 100), rateIndex: 8, channels: 1)  // 16 kHz
        let builder = AudioSampleBuilder()
        XCTAssertTrue(builder.noteFormat(adts: frame))
        XCTAssertEqual(builder.sampleRate, 16000)
        let asbd = try XCTUnwrap(builder.formatDescription.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee })
        XCTAssertEqual(asbd.mFormatID, kAudioFormatMPEG4AAC)
        XCTAssertEqual(asbd.mChannelsPerFrame, 1)
        XCTAssertEqual(asbd.mFramesPerPacket, 1024)
        let sample = try XCTUnwrap(builder.sampleBuffer(adts: frame, presentationTime: CMTime(value: 2048, timescale: 16000)))
        XCTAssertEqual(CMSampleBufferGetTotalSampleSize(sample), 100)
        XCTAssertEqual(CMSampleBufferGetPresentationTimeStamp(sample), CMTime(value: 2048, timescale: 16000))
    }

    func testRejectsWhatIsNotADTS() {
        XCTAssertFalse(AudioSampleBuilder().noteFormat(adts: Data([1, 2, 3, 4, 5, 6, 7, 8])))
    }
}
