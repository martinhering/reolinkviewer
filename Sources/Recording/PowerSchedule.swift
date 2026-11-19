import Foundation

/// The Mac's repeating wake time, as `pmset` knows it. A sleeping Mac records nothing, and
/// only this schedule (set with administrator rights) wakes it for the recording window.
public enum PowerSchedule {
    /// A repeating wake event: minutes after midnight, and on which days in pmset's words.
    public struct Wake: Equatable, Sendable {
        public var minute: Int
        public var days: String

        public var isEveryDay: Bool { days == "every day" }
    }

    /// How long before the window starts the Mac is woken, and from when the recorder keeps
    /// it awake.
    public static let leadSeconds = 120

    /// When to wake for a window that starts at `startMinute`.
    public static func wakeMinute(forStart startMinute: Int) -> Int {
        (startMinute - leadSeconds / 60 + 1440) % 1440
    }

    /// Reads the repeating wake event out of the output of `pmset -g sched`, which has lines
    /// like `  wakepoweron at 7:58PM every day`.
    public static func parseRepeatingWake(_ output: String) -> Wake? {
        var inRepeating = false
        for line in output.split(separator: "\n").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            if line.hasSuffix(":") {
                inRepeating = line.lowercased().hasPrefix("repeating")
                continue
            }
            guard inRepeating else { continue }
            let words = line.split(separator: " ").map(String.init)
            guard words.count >= 3, ["wake", "wakepoweron", "wakeorpoweron", "poweron"].contains(words[0].lowercased()),
                  words[1] == "at", let minute = minute(of: words[2]) else { continue }
            return Wake(minute: minute, days: words.dropFirst(3).joined(separator: " "))
        }
        return nil
    }

    /// `7:58PM`, `12:05AM` or `19:58` as minutes after midnight.
    static func minute(of text: String) -> Int? {
        let upper = text.uppercased()
        let suffix = upper.hasSuffix("AM") ? "AM" : upper.hasSuffix("PM") ? "PM" : ""
        let parts = upper.dropLast(suffix.count).split(separator: ":")
        guard parts.count >= 2, var hour = Int(parts[0]), let minute = Int(parts[1]), (0..<60).contains(minute) else { return nil }
        if suffix == "PM", hour < 12 { hour += 12 }
        if suffix == "AM", hour == 12 { hour = 0 }
        guard (0..<24).contains(hour) else { return nil }
        return hour * 60 + minute
    }

    /// `19:58:00`, as `pmset repeat` wants it.
    public static func pmsetTime(_ minute: Int) -> String {
        String(format: "%02d:%02d:00", minute / 60, minute % 60)
    }
}
