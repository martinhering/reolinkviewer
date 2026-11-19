import Foundation
import Recording
import Security
import ServiceManagement

/// The background recorder: the app started with `--recorder`, without a window. A LaunchAgent
/// starts it at login (see `RecorderAgent`); it then waits for the daily window and records.
///
/// Environment, for running it from Terminal:
///   REOLINK_RECORDINGS_DIR  write to this folder instead of Application Support
///   REOLINK_PASSWORD        as for the app: overrides every keychain password
enum RecorderProcess {
    static let argument = "--recorder"

    static func run() -> Never {
        let log = RecorderLog()
        var directory = RecordingStore.defaultDirectory
        if let override = ProcessInfo.processInfo.environment["REOLINK_RECORDINGS_DIR"], !override.isEmpty {
            directory = URL(fileURLWithPath: override, isDirectory: true)
        }
        guard let lock = InstanceLock(folder: directory) else {
            log.write("another recorder is already running on \(directory.path); leaving")
            exit(0)
        }
        let service = RecordingService(
            directory: directory, log: { log.write($0) },
            loadSettings: { RecordingSettings.load() },
            loadCameras: {
                SettingsStore.load().filter(\.isComplete).map {
                    RecorderCamera(id: $0.id, name: $0.displayName, host: $0.host, port: $0.port,
                                   username: $0.username, password: $0.password)
                }
            },
            loadStorage: { StorageStore.loadSetup() })
        let task = Task { await service.run() }

        // The app tells us when cameras or settings were saved.
        let observer = DistributedNotificationCenter.default().addObserver(
            forName: RecordingSettings.changedNotification, object: nil, queue: nil
        ) { _ in
            Task { await service.configurationChanged() }
        }

        // launchd stops the agent with SIGTERM: close the running files first.
        var sources: [DispatchSourceSignal] = []
        for number in [SIGTERM, SIGINT] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler {
                task.cancel()
                Task {
                    await task.value
                    _ = lock
                    exit(0)
                }
            }
            source.resume()
            sources.append(source)
        }
        withExtendedLifetime((observer, sources)) {
            dispatchMain()
        }
    }
}

/// Appends time-stamped lines to `~/Library/Logs/ReolinkViewer/recorder.log`.
final class RecorderLog: @unchecked Sendable {
    static var url: URL {
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library")
        return library.appendingPathComponent("Logs/ReolinkViewer/recorder.log")
    }

    private let lock = NSLock()
    private var handle: FileHandle?
    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    init() {
        let url = Self.url
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Start afresh once the file has grown past 2 MB, keeping one old copy.
        if let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue, size > 2_000_000 {
            let old = url.deletingPathExtension().appendingPathExtension("old.log")
            try? fm.removeItem(at: old)
            try? fm.moveItem(at: url, to: old)
        }
        if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
        handle = FileHandle(forWritingAtPath: url.path)
        _ = try? handle?.seekToEnd()
    }

    func write(_ line: String) {
        lock.lock(); defer { lock.unlock() }
        let text = "\(formatter.string(from: Date()))  \(line)\n"
        try? handle?.write(contentsOf: Data(text.utf8))
        FileHandle.standardError.write(Data(text.utf8))
    }
}

/// A lock file that makes sure only one recorder writes to a recordings folder. Held for as
/// long as the object lives.
final class InstanceLock {
    private let descriptor: Int32

    init?(folder: URL) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let fd = open(folder.appendingPathComponent("recorder.lock").path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { return nil }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            return nil
        }
        descriptor = fd
    }

    deinit {
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }
}

/// Registers the recorder as a LaunchAgent, so macOS starts it at login and keeps it running
/// while the app is closed. The agent's property list lives in the app bundle
/// (`Contents/Library/LaunchAgents`), so this only works from the built app.
enum RecorderAgent {
    static let plistName = "com.martinhering.ReolinkViewer.recorder.plist"

    private static var service: SMAppService { SMAppService.agent(plistName: plistName) }

    /// Whether this process runs from an app bundle that carries the agent's property list.
    static var isAvailable: Bool {
        FileManager.default.fileExists(atPath: Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/LaunchAgents/\(plistName)").path)
    }

    static var isRegistered: Bool {
        service.status == .enabled
    }

    /// What to tell the user about the agent.
    static var statusText: String {
        guard isAvailable else { return "Only the built app can start the background recorder (build-app.sh)." }
        switch service.status {
        case .enabled: return "The background recorder starts at login and runs while the app is closed."
        case .requiresApproval: return "Allow “Reolink Viewer” under System Settings › General › Login Items."
        case .notRegistered: return "The background recorder is not installed."
        case .notFound: return "The background recorder is missing from the app bundle."
        @unknown default: return "The state of the background recorder is unknown."
        }
    }

    static func setRegistered(_ on: Bool) throws {
        if on {
            if service.status != .enabled { try service.register() }
        } else if service.status != .notRegistered {
            try service.unregister()
        }
    }

    /// An ad-hoc signature changes with every build, and with it the identity the keychain
    /// knows the app by: the recorder would then be asked for every camera password again,
    /// with nobody there to answer.
    static var isAdHocSigned: Bool {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return false }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return false }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return false }
        let flags = (dict[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
        return flags & SecCodeSignatureFlags.adhoc.rawValue != 0
    }
}
