import Foundation
import Recording

/// Reads and sets the Mac's repeating wake time with `pmset`. Reading needs no rights;
/// setting runs `pmset repeat` as administrator, for which macOS asks for a password.
enum WakeSchedule {
    static func current() -> PowerSchedule.Wake? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-g", "sched"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return PowerSchedule.parseRepeatingWake(String(decoding: data, as: UTF8.self))
    }

    /// Wakes the Mac every day at `minute`, or removes the repeating schedule when nil.
    /// Returns what went wrong, or nil. Cancelling the password prompt is not an error.
    static func set(_ minute: Int?) -> String? {
        let command = minute.map { "/usr/bin/pmset repeat wakeorpoweron MTWRFSU \(PowerSchedule.pmsetTime($0))" }
            ?? "/usr/bin/pmset repeat cancel"
        let script = "do shell script \"\(command)\" with administrator privileges"
        // osascript shows the password prompt; the app itself needs no extra rights for it.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return "The wake time could not be set: \(error.localizedDescription)"
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus != 0 else { return nil }
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if text.contains("-128") { return nil }  // the prompt was cancelled
        return "The wake time could not be set: \(text)"
    }
}
