import Baichuan
import Foundation

/// The daily time span in which the recorder runs, in minutes after local midnight.
/// It may wrap over midnight (22:00 to 06:00); equal start and stop mean the whole day.
public struct RecordingWindow: Equatable, Sendable {
    public var startMinute: Int
    public var stopMinute: Int

    public init(startMinute: Int, stopMinute: Int) {
        self.startMinute = min(max(startMinute, 0), 1439)
        self.stopMinute = min(max(stopMinute, 0), 1439)
    }

    public func contains(_ date: Date, calendar: Calendar = .autoupdatingCurrent) -> Bool {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        if startMinute == stopMinute { return true }
        if startMinute < stopMinute { return minute >= startMinute && minute < stopMinute }
        return minute >= startMinute || minute < stopMinute
    }
}

/// The recording settings, one set for all cameras. Stored in the app's preferences, one key
/// per field, so the app and the background recorder (the same bundle) read the same values.
public struct RecordingSettings: Equatable, Sendable {
    public enum Keep: String, CaseIterable, Sendable, Identifiable {
        /// Only segments that motion touches.
        case motionOnly
        case everything
        public var id: String { rawValue }
    }

    /// Record all cameras.
    public var enabled = false
    /// Minutes after local midnight; nil until a window has been chosen.
    public var startMinute: Int?
    public var stopMinute: Int?
    public var stream: StreamKind = .main
    public var audio = true
    public var keep: Keep = .motionOnly
    /// Seconds per file.
    public var segmentLength = 60
    /// Seconds by which motion is widened before it is matched against a segment.
    public var paddingBefore = 10
    public var paddingAfter = 20
    /// Days a kept file stays on this Mac.
    public var localCacheDays = 2
    /// Override the cameras' own setting for the recording period: cameras with a spotlight
    /// light it on motion in the dark. Afterwards each camera gets its own setting back.
    public var floodlight = false

    public init() {}

    public var window: RecordingWindow? {
        guard let startMinute, let stopMinute else { return nil }
        return RecordingWindow(startMinute: startMinute, stopMinute: stopMinute)
    }

    /// Whether the recorder should be pulling streams at `date`.
    public func isActive(at date: Date, calendar: Calendar = .autoupdatingCurrent) -> Bool {
        enabled && (window?.contains(date, calendar: calendar) ?? false)
    }

    /// The fields a running camera recorder depends on. A change in any of them restarts it;
    /// a change of the window does not.
    public struct Parameters: Equatable, Sendable {
        public var stream: StreamKind = .main
        public var audio = true
        public var keep: Keep = .motionOnly
        public var segmentLength = 60
        public var paddingBefore = 10
        public var paddingAfter = 20
        public var floodlight = false

        public init() {}
    }

    public var parameters: Parameters {
        var p = Parameters()
        p.stream = stream
        p.audio = audio
        p.keep = keep
        p.segmentLength = segmentLength
        p.paddingBefore = paddingBefore
        p.paddingAfter = paddingAfter
        p.floodlight = floodlight
        return p
    }

    // MARK: Storage

    /// Posted through `DistributedNotificationCenter` after the app saved settings or cameras,
    /// so the background recorder picks them up at once.
    public static let changedNotification = Notification.Name("com.martinhering.ReolinkViewer.recordingSettingsChanged")

    private enum Key {
        static let enabled = "recording.enabled"
        static let startMinute = "recording.startMinute"
        static let stopMinute = "recording.stopMinute"
        static let stream = "recording.stream"
        static let audio = "recording.audio"
        static let keep = "recording.keep"
        static let segmentLength = "recording.segmentLength"
        static let paddingBefore = "recording.paddingBefore"
        static let paddingAfter = "recording.paddingAfter"
        static let localCacheDays = "recording.localCacheDays"
        static let floodlight = "recording.floodlight"
    }

    public static func load(from defaults: UserDefaults = .standard) -> RecordingSettings {
        var s = RecordingSettings()
        func int(_ key: String, _ range: ClosedRange<Int>) -> Int? {
            guard defaults.object(forKey: key) != nil else { return nil }
            return min(max(defaults.integer(forKey: key), range.lowerBound), range.upperBound)
        }
        s.enabled = defaults.bool(forKey: Key.enabled)
        s.startMinute = int(Key.startMinute, 0...1439)
        s.stopMinute = int(Key.stopMinute, 0...1439)
        s.stream = defaults.string(forKey: Key.stream).flatMap(StreamKind.init(rawValue:)) ?? s.stream
        if defaults.object(forKey: Key.audio) != nil { s.audio = defaults.bool(forKey: Key.audio) }
        s.keep = defaults.string(forKey: Key.keep).flatMap(Keep.init(rawValue:)) ?? s.keep
        s.segmentLength = int(Key.segmentLength, 10...600) ?? s.segmentLength
        s.paddingBefore = int(Key.paddingBefore, 0...120) ?? s.paddingBefore
        s.paddingAfter = int(Key.paddingAfter, 0...120) ?? s.paddingAfter
        s.localCacheDays = int(Key.localCacheDays, 1...365) ?? s.localCacheDays
        s.floodlight = defaults.bool(forKey: Key.floodlight)
        return s
    }

    public func save(to defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: Key.enabled)
        if let startMinute { defaults.set(startMinute, forKey: Key.startMinute) } else { defaults.removeObject(forKey: Key.startMinute) }
        if let stopMinute { defaults.set(stopMinute, forKey: Key.stopMinute) } else { defaults.removeObject(forKey: Key.stopMinute) }
        defaults.set(stream.rawValue, forKey: Key.stream)
        defaults.set(audio, forKey: Key.audio)
        defaults.set(keep.rawValue, forKey: Key.keep)
        defaults.set(segmentLength, forKey: Key.segmentLength)
        defaults.set(paddingBefore, forKey: Key.paddingBefore)
        defaults.set(paddingAfter, forKey: Key.paddingAfter)
        defaults.set(localCacheDays, forKey: Key.localCacheDays)
        defaults.set(floodlight, forKey: Key.floodlight)
    }
}
