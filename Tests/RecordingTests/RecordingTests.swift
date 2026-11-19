import Foundation
import XCTest
@testable import Recording

final class RecordingWindowTests: XCTestCase {
    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return c
    }()

    private func at(_ hour: Int, _ minute: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: 19, hour: hour, minute: minute, second: 30))!
    }

    func testWindowWithinOneDay() {
        let window = RecordingWindow(startMinute: 8 * 60, stopMinute: 17 * 60)
        XCTAssertFalse(window.contains(at(7, 59), calendar: calendar))
        XCTAssertTrue(window.contains(at(8, 0), calendar: calendar))
        XCTAssertTrue(window.contains(at(16, 59), calendar: calendar))
        XCTAssertFalse(window.contains(at(17, 0), calendar: calendar))
    }

    func testWindowOverMidnight() {
        let window = RecordingWindow(startMinute: 22 * 60, stopMinute: 6 * 60)
        XCTAssertTrue(window.contains(at(22, 0), calendar: calendar))
        XCTAssertTrue(window.contains(at(23, 59), calendar: calendar))
        XCTAssertTrue(window.contains(at(0, 0), calendar: calendar))
        XCTAssertTrue(window.contains(at(5, 59), calendar: calendar))
        XCTAssertFalse(window.contains(at(6, 0), calendar: calendar))
        XCTAssertFalse(window.contains(at(12, 0), calendar: calendar))
    }

    func testEqualTimesMeanTheWholeDay() {
        let window = RecordingWindow(startMinute: 600, stopMinute: 600)
        XCTAssertTrue(window.contains(at(3, 0), calendar: calendar))
        XCTAssertTrue(window.contains(at(10, 0), calendar: calendar))
    }
}

final class RecordingSettingsTests: XCTestCase {
    private func scratchDefaults() -> UserDefaults {
        let name = "RecordingSettingsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    func testDefaultsMatchThePlan() {
        let s = RecordingSettings.load(from: scratchDefaults())
        XCTAssertFalse(s.enabled)
        XCTAssertNil(s.window)
        XCTAssertEqual(s.stream, .main)
        XCTAssertTrue(s.audio)
        XCTAssertEqual(s.keep, .motionOnly)
        XCTAssertEqual([s.segmentLength, s.paddingBefore, s.paddingAfter, s.localCacheDays], [60, 10, 20, 2])
        XCTAssertFalse(s.isActive(at: Date()))
        XCTAssertFalse(s.floodlight)
    }

    func testRoundTrip() {
        let defaults = scratchDefaults()
        var s = RecordingSettings()
        s.enabled = true
        s.startMinute = 1320
        s.stopMinute = 360
        s.stream = .sub
        s.audio = false
        s.keep = .everything
        s.segmentLength = 30
        s.paddingBefore = 5
        s.paddingAfter = 15
        s.localCacheDays = 7
        s.floodlight = true
        s.save(to: defaults)
        XCTAssertEqual(RecordingSettings.load(from: defaults), s)
        s.startMinute = nil
        s.save(to: defaults)
        XCTAssertNil(RecordingSettings.load(from: defaults).window)
    }

    func testEnabledWithoutAWindowRecordsNothing() {
        var s = RecordingSettings()
        s.enabled = true
        XCTAssertFalse(s.isActive(at: Date()))
        s.startMinute = 0
        s.stopMinute = 0
        XCTAssertTrue(s.isActive(at: Date()))
        s.enabled = false
        XCTAssertFalse(s.isActive(at: Date()))
    }

    func testOutOfRangeValuesAreClamped() {
        let defaults = scratchDefaults()
        defaults.set(1, forKey: "recording.segmentLength")
        defaults.set(5000, forKey: "recording.startMinute")
        let s = RecordingSettings.load(from: defaults)
        XCTAssertEqual(s.segmentLength, 10)
        XCTAssertEqual(s.startMinute, 1439)
    }

    func testTheWindowIsNotARecorderParameter() {
        var a = RecordingSettings(), b = RecordingSettings()
        b.startMinute = 5
        b.enabled = true
        b.localCacheDays = 9
        XCTAssertEqual(a.parameters, b.parameters)
        a.audio = false
        XCTAssertNotEqual(a.parameters, b.parameters)
    }
}

final class MotionLogTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_795_082_400)
    private func t(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }
    /// The minute from 60 s to 120 s.
    private var minute: DateInterval { DateInterval(start: t(60), end: t(120)) }

    private func log(motionFrom start: TimeInterval, to end: TimeInterval?) -> MotionLog {
        var log = MotionLog()
        log.report(true, at: t(start))
        if let end { log.report(false, at: t(end)) }
        return log
    }

    func testMotionInsideTheMinuteKeepsIt() {
        XCTAssertTrue(log(motionFrom: 80, to: 85).touches(minute, before: 10, after: 20, now: t(130)))
    }

    func testNoMotionDeletesIt() {
        XCTAssertFalse(MotionLog().touches(minute, before: 10, after: 20, now: t(130)))
    }

    func testMotionThatStartsShortlyAfterwardsReachesBack() {
        // Starts 10 s after the minute ends: the padding before just touches it.
        XCTAssertTrue(log(motionFrom: 130, to: 140).touches(minute, before: 10, after: 20, now: t(200)))
        XCTAssertFalse(log(motionFrom: 131, to: 140).touches(minute, before: 10, after: 20, now: t(200)))
    }

    func testMotionThatEndedShortlyBeforeReachesForward() {
        XCTAssertTrue(log(motionFrom: 30, to: 40).touches(minute, before: 10, after: 20, now: t(200)))
        XCTAssertFalse(log(motionFrom: 30, to: 39).touches(minute, before: 10, after: 20, now: t(200)))
    }

    func testOngoingMotionCounts() {
        let open = log(motionFrom: 20, to: nil)
        XCTAssertTrue(open.touches(minute, before: 10, after: 20, now: t(130)))
        XCTAssertEqual(open.spans(in: minute, now: t(130)), [minute])
    }

    func testRepeatedReportsDoNotSplitASpan() {
        var log = MotionLog()
        log.report(true, at: t(70))
        log.report(true, at: t(75))
        log.report(false, at: t(80))
        log.report(false, at: t(90))
        XCTAssertEqual(log.spans, [DateInterval(start: t(70), end: t(80))])
    }

    func testSpansAreClippedToTheSegment() {
        var log = self.log(motionFrom: 50, to: 70)
        log.report(true, at: t(110))
        log.report(false, at: t(150))
        XCTAssertEqual(log.spans(in: minute, now: t(200)),
                       [DateInterval(start: t(60), end: t(70)), DateInterval(start: t(110), end: t(120))])
    }

    func testPruneForgetsOldSpansOnly() {
        var log = self.log(motionFrom: 10, to: 20)
        log.report(true, at: t(100))
        log.report(false, at: t(110))
        log.report(true, at: t(300))
        log.prune(before: t(50))
        XCTAssertEqual(log.spans, [DateInterval(start: t(100), end: t(110))])
        XCTAssertEqual(log.openSince, t(300))
    }
}

final class FrameSizeMotionDetectorTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_795_082_400)

    /// Feeds 15 frames a second of `bytes` each for `seconds`, returns the state changes with their times.
    private func feed(_ detector: inout FrameSizeMotionDetector, from start: Double, seconds: Double, bytes: (Double) -> Int) -> [(Double, Bool)] {
        var changes: [(Double, Bool)] = []
        var time = start
        while time < start + seconds {
            if let change = detector.add(bytes: bytes(time), at: t0.addingTimeInterval(time)) { changes.append((time, change)) }
            time += 1.0 / 15
        }
        return changes
    }

    func testQuietSceneIsNoMotion() {
        var detector = FrameSizeMotionDetector()
        // Sizes wobble by a quarter around 2000 bytes.
        let changes = feed(&detector, from: 0, seconds: 60) { 2000 + Int(500 * sin($0 * 3)) }
        XCTAssertTrue(changes.isEmpty)
    }

    func testLargerFramesStartMotionAndSmallerOnesEndIt() {
        var detector = FrameSizeMotionDetector()
        XCTAssertTrue(feed(&detector, from: 0, seconds: 20) { _ in 2000 }.isEmpty)
        let started = feed(&detector, from: 20, seconds: 10) { _ in 6000 }
        XCTAssertEqual(started.count, 1)
        XCTAssertEqual(started.first?.1, true)
        XCTAssertLessThan(started.first?.0 ?? 99, 24)
        let stopped = feed(&detector, from: 30, seconds: 10) { _ in 2000 }
        XCTAssertEqual(stopped.count, 1)
        XCTAssertEqual(stopped.first?.1, false)
        XCTAssertLessThan(stopped.first?.0 ?? 99, 36)
    }

    func testSlowDriftIsFollowed() {
        var detector = FrameSizeMotionDetector()
        // Doubles over two minutes, as when dusk brings sensor noise.
        let changes = feed(&detector, from: 0, seconds: 120) { 2000 + Int($0 / 120 * 2000) }
        XCTAssertTrue(changes.isEmpty)
    }

    func testALastingChangeEndsAfterAWhile() {
        var detector = FrameSizeMotionDetector()
        _ = feed(&detector, from: 0, seconds: 20) { _ in 2000 }
        let changes = feed(&detector, from: 20, seconds: 600) { _ in 4000 }
        XCTAssertEqual(changes.map(\.1), [true, false])
    }
}

final class RecordingStoreTests: XCTestCase {
    func testRemovesOnlyExpiredKeptFiles() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("RecordingStoreTests-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let camera = RecordingStore.directory(for: UUID(), in: root)
        let now = Date()
        func make(_ path: String, ageDays: Double) throws -> URL {
            let url = camera.appendingPathComponent(path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data([1]).write(to: url)
            try fm.setAttributes([.modificationDate: now.addingTimeInterval(-ageDays * 86400)], ofItemAtPath: url.path)
            return url
        }
        let old = try make("2026-11-16/100000Z_60s.mp4", ageDays: 3)
        let mixedOld = try make("2026-11-17/230000Z_60s.mp4", ageDays: 2.1)
        let mixedNew = try make("2026-11-17/235900Z_60s.mp4", ageDays: 1.9)
        let fresh = try make("2026-11-19/100000Z_60s.mp4", ageDays: 0)
        let pending = try make("pending/2026-11-16/100000Z_60s.mp4", ageDays: 3)

        XCTAssertEqual(RecordingStore.removeExpired(in: root, olderThan: 2, now: now), 2)
        XCTAssertFalse(fm.fileExists(atPath: old.path))
        XCTAssertFalse(fm.fileExists(atPath: old.deletingLastPathComponent().path), "the emptied day folder goes too")
        XCTAssertFalse(fm.fileExists(atPath: mixedOld.path))
        XCTAssertTrue(fm.fileExists(atPath: mixedNew.path))
        XCTAssertTrue(fm.fileExists(atPath: fresh.path))
        XCTAssertTrue(fm.fileExists(atPath: pending.path))
    }
}

final class PowerScheduleTests: XCTestCase {
    func testReadsTheRepeatingWake() {
        let output = """
        Repeating power events:
          wakepoweron at 7:58PM every day
        Scheduled power events:
         [0]  wake at 11/20/2026 03:00:00 by 'com.apple.alarm.user-visible'
        """
        XCTAssertEqual(PowerSchedule.parseRepeatingWake(output), PowerSchedule.Wake(minute: 19 * 60 + 58, days: "every day"))
        XCTAssertEqual(PowerSchedule.parseRepeatingWake(output)?.isEveryDay, true)
    }

    func testIgnoresOneOffEventsAndRepeatingSleep() {
        XCTAssertNil(PowerSchedule.parseRepeatingWake(""))
        XCTAssertNil(PowerSchedule.parseRepeatingWake("Scheduled power events:\n [0]  wake at 11/20/2026 03:00:00 by 'x'\n"))
        let both = "Repeating power events:\n  sleep at 11:00PM every day\n  wake at 6:30AM weekdays only\n"
        XCTAssertEqual(PowerSchedule.parseRepeatingWake(both), PowerSchedule.Wake(minute: 390, days: "weekdays only"))
        XCTAssertEqual(PowerSchedule.parseRepeatingWake(both)?.isEveryDay, false)
    }

    func testClockForms() {
        XCTAssertEqual(PowerSchedule.minute(of: "12:05AM"), 5)
        XCTAssertEqual(PowerSchedule.minute(of: "12:00PM"), 720)
        XCTAssertEqual(PowerSchedule.minute(of: "19:58"), 1198)
        XCTAssertNil(PowerSchedule.minute(of: "soon"))
    }

    func testWakesTwoMinutesBeforeTheWindow() {
        XCTAssertEqual(PowerSchedule.wakeMinute(forStart: 20 * 60), 19 * 60 + 58)
        XCTAssertEqual(PowerSchedule.wakeMinute(forStart: 1), 1439, "wraps over midnight")
        XCTAssertEqual(PowerSchedule.pmsetTime(19 * 60 + 58), "19:58:00")
        XCTAssertEqual(PowerSchedule.pmsetTime(5), "00:05:00")
    }
}
