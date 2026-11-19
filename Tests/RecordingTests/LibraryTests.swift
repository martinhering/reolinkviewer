import Foundation
import XCTest
@testable import Recording

final class RecordingsModelTests: XCTestCase {
    private let a = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
    private let b = UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!
    private let tenOClock = Date(timeIntervalSince1970: 1_795_082_400)  // 2026-11-19 10:00:00 UTC

    private func file(_ minute: Int, motion: [[Double]] = []) -> DayIndex.File {
        let start = tenOClock.addingTimeInterval(Double(minute) * 60)
        return DayIndex.File(name: "\(minute).mp4.enc", start: start, duration: 60, bytes: 1, motion: motion)
    }

    private func recordings() -> Recordings {
        var index = DayIndex(day: "2026-11-19")
        index.add(file(2), camera: a, cameraName: "Alpha")
        index.add(file(0), camera: a, cameraName: "Alpha")
        index.add(file(1), camera: a, cameraName: "Alpha")
        index.add(file(1), camera: b, cameraName: "Beta")
        index.add(file(5), camera: b, cameraName: "Beta")
        return Recordings.merging([index], within: DateInterval(start: tenOClock.addingTimeInterval(-3600), duration: 86400), order: [b, a])
    }

    func testCamerasFollowTheGivenOrderAndClipsTheTime() {
        let r = recordings()
        XCTAssertEqual(r.cameras.map(\.name), ["Beta", "Alpha"])
        XCTAssertEqual(r.clips(of: a).map(\.name), ["0.mp4.enc", "1.mp4.enc", "2.mp4.enc"])
        XCTAssertEqual(r.earliestStart, tenOClock)
        XCTAssertEqual(r.clips(of: a)[0].objectKey, "recordings/\(a.uuidString)/2026-11-19/0.mp4.enc")
    }

    func testFindsTheClipUnderAMoment() {
        let r = recordings()
        XCTAssertEqual(r.clip(of: a, at: tenOClock.addingTimeInterval(90))?.name, "1.mp4.enc")
        XCTAssertEqual(r.clip(of: a, at: tenOClock.addingTimeInterval(60))?.name, "1.mp4.enc", "a boundary belongs to the later clip")
        XCTAssertNil(r.clip(of: a, at: tenOClock.addingTimeInterval(180)))
        XCTAssertNil(r.clip(of: b, at: tenOClock.addingTimeInterval(30)))
    }

    func testNextStartSkipsGapsAcrossCameras() {
        let r = recordings()
        XCTAssertEqual(r.nextStart(after: tenOClock.addingTimeInterval(170)), tenOClock.addingTimeInterval(300))
        XCTAssertEqual(r.nextStart(after: tenOClock.addingTimeInterval(10), cameras: [b]), tenOClock.addingTimeInterval(60))
        XCTAssertNil(r.nextStart(after: tenOClock.addingTimeInterval(300)))
        let first = r.clips(of: a)[0]
        XCTAssertEqual(r.clip(after: first)?.name, "1.mp4.enc")
        XCTAssertNil(r.clip(after: r.clips(of: a)[2]))
    }

    func testUnknownCamerasComeLastByName() {
        var index = DayIndex(day: "2026-11-19")
        index.add(file(0), camera: a, cameraName: "Zeta")
        index.add(file(0), camera: b, cameraName: "Eta")
        let r = Recordings.merging([index], within: DateInterval(start: tenOClock, duration: 3600), order: [])
        XCTAssertEqual(r.cameras.map(\.name), ["Eta", "Zeta"])
    }

    func testOnlyClipsInsideTheSpanAndMotionAsIntervals() {
        var index = DayIndex(day: "2026-11-19")
        let t = tenOClock.timeIntervalSince1970
        index.add(file(0, motion: [[t + 5, t + 15], [t + 9]]), camera: a, cameraName: "Alpha")
        index.add(file(120), camera: a, cameraName: "Alpha")
        let r = Recordings.merging([index], within: DateInterval(start: tenOClock, duration: 3600), order: [a])
        XCTAssertEqual(r.clips(of: a).count, 1)
        XCTAssertEqual(r.clips(of: a)[0].motion, [DateInterval(start: tenOClock.addingTimeInterval(5), duration: 10)])
    }

    func testALocalDayCanSpanTwoUTCDays() {
        // 19 November in Berlin (UTC+1): 18 Nov 23:00 UTC to 19 Nov 23:00 UTC.
        let start = Date(timeIntervalSince1970: 1_795_082_400 - 11 * 3600)
        XCTAssertEqual(Recordings.days(covering: DateInterval(start: start, duration: 86400)), ["2026-11-18", "2026-11-19"])
        let utcDay = Date(timeIntervalSince1970: 1_795_082_400 - 10 * 3600)
        XCTAssertEqual(Recordings.days(covering: DateInterval(start: utcDay, duration: 86400)), ["2026-11-19"])
    }
}

final class RecordingLibraryTests: XCTestCase {
    private var root: URL!
    private let camera = UUID(uuidString: "02AC1B31-8439-40D6-8453-61E11CC5CBFD")!
    private let vault = Vault.generate()
    private let tenOClock = Date(timeIntervalSince1970: 1_795_082_400)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("LibraryTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        StubProtocol.handler = nil
        StubProtocol.requests = []
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// Records one file through the uploader, as the recorder would.
    private func recordOne() async throws -> Clip {
        let setup = StorageSetup(configuration: S3Configuration(endpoint: URL(string: "https://s3.example.com")!, region: "eu", bucket: "cams"),
                                 credentials: S3Credentials(accessKeyID: "id", secretAccessKey: "secret"), vault: vault)
        let uploader = Uploader(root: root, setup: setup, session: StubProtocol.session(), log: { _ in })
        let url = RecordingStore.directory(for: camera, in: root).appendingPathComponent("2026-11-19/100000Z_60s.mp4")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("the clip".utf8).write(to: url)
        await uploader.enqueue(file: url, camera: camera, cameraName: "Lab", start: tenOClock, duration: 60, motion: [])
        while await uploader.uploadNext() != nil {}
        StubProtocol.requests = []
        let index = try await RecordingLibrary(root: root, vault: vault, reader: nil).index(day: "2026-11-19")
        let file = try XCTUnwrap(index?.cameras[camera.uuidString]?.files.first)
        return Clip(camera: camera, day: "2026-11-19", file: file)
    }

    func testPlaysFromTheLocalCacheWithoutAKey() async throws {
        let clip = try await recordOne()
        let library = RecordingLibrary(root: root, vault: vault, reader: nil)
        XCTAssertFalse(library.canDownload)
        let data = try await library.data(for: clip)
        XCTAssertEqual(data, Data("the clip".utf8))
        let missing = try await library.index(day: "2026-11-18")
        XCTAssertNil(missing)
        XCTAssertTrue(StubProtocol.requests.isEmpty, "nothing is fetched")
    }

    func testAClipThatLeftTheCacheNeedsAKey() async throws {
        let clip = try await recordOne()
        try FileManager.default.removeItem(at: RecordingStore.directory(for: camera, in: root).appendingPathComponent("2026-11-19/\(clip.name)"))
        let library = RecordingLibrary(root: root, vault: vault, reader: nil)
        do {
            _ = try await library.data(for: clip)
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue(error is LibraryError)
        }
    }

    func testAnotherKeyDoesNotOpenTheRecordings() async throws {
        let clip = try await recordOne()
        let stranger = RecordingLibrary(root: root, vault: Vault.generate(), reader: nil)
        do {
            _ = try await stranger.index(day: "2026-11-19")
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue(error is VaultError)
        }
        do {
            _ = try await stranger.data(for: clip)
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue(error is LibraryError, "an unreadable cache file counts as missing")
        }
    }
}
