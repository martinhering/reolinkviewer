import Foundation

/// The local folder that holds the recordings: `<root>/<camera id>/yyyy-MM-dd/HHmmssZ_60s.mp4`,
/// plus `<root>/<camera id>/pending/` for segments not yet judged.
public enum RecordingStore {
    /// `~/Library/Application Support/ReolinkViewer/Recordings`.
    public static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("ReolinkViewer/Recordings", isDirectory: true)
    }

    public static func directory(for camera: UUID, in root: URL) -> URL {
        root.appendingPathComponent(camera.uuidString, isDirectory: true)
    }

    /// Deletes kept segments older than `days` and the day folders this empties. Leaves the
    /// pending folders alone. Returns how many files it removed.
    @discardableResult
    public static func removeExpired(in root: URL, olderThan days: Int, now: Date = Date()) -> Int {
        let fm = FileManager.default
        let limit = now.addingTimeInterval(-TimeInterval(days) * 86400)
        var removed = 0
        let keys: [URLResourceKey] = [.isDirectoryKey, .contentModificationDateKey]
        for camera in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: keys)) ?? [] {
            for day in (try? fm.contentsOfDirectory(at: camera, includingPropertiesForKeys: keys)) ?? [] {
                guard day.lastPathComponent != "pending",
                      (try? day.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
                let files = (try? fm.contentsOfDirectory(at: day, includingPropertiesForKeys: keys)) ?? []
                var left = files.count
                for file in files {
                    guard let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                          modified < limit else { continue }
                    if (try? fm.removeItem(at: file)) != nil {
                        removed += 1
                        left -= 1
                    }
                }
                if left == 0 { try? fm.removeItem(at: day) }
            }
        }
        return removed
    }
}

/// Runs the recording: looks at the settings once a second, records every camera while the
/// daily window is open, keeps the Mac awake meanwhile, and clears out expired files.
public actor RecordingService {
    private let directory: URL
    private let log: @Sendable (String) -> Void
    private let loadSettings: @Sendable () -> RecordingSettings
    private let loadCameras: @Sendable () -> [RecorderCamera]
    private let loadStorage: @Sendable () -> StorageSetup?

    private struct Running {
        let camera: RecorderCamera
        let parameters: RecordingSettings.Parameters
        let recorder: CameraRecorder
    }

    private var running: [UUID: Running] = [:]
    private var cameras: [RecorderCamera] = []
    private var camerasLoaded = Date.distantPast
    private var lastCleanup = Date.distantPast
    private var awake: NSObjectProtocol?
    private var wasActive: Bool?
    private var storageStale = true
    private var storageFingerprint: String?
    private var uploader: Uploader?
    private var uploadTask: Task<Void, Never>?

    /// - Parameters:
    ///   - loadSettings: called every second; must be cheap.
    ///   - loadCameras: called when recording starts, once a minute while it runs, and after
    ///     `configurationChanged()`. May read the keychain.
    ///   - loadStorage: called at the start and after `configurationChanged()`; nil while no
    ///     off-site storage is set up. Kept files then stay on the Mac as they are.
    public init(directory: URL = RecordingStore.defaultDirectory, log: @escaping @Sendable (String) -> Void,
                loadSettings: @escaping @Sendable () -> RecordingSettings,
                loadCameras: @escaping @Sendable () -> [RecorderCamera],
                loadStorage: @escaping @Sendable () -> StorageSetup? = { nil }) {
        self.directory = directory
        self.log = log
        self.loadSettings = loadSettings
        self.loadCameras = loadCameras
        self.loadStorage = loadStorage
    }

    /// Runs until the task is cancelled, then stops every recorder and returns.
    public func run() async {
        log("recorder started, folder \(directory.path)")
        while !Task.isCancelled {
            await tick(now: Date())
            try? await Task.sleep(for: .seconds(1))
        }
        await reconcile(with: [], parameters: RecordingSettings.Parameters())
        uploadTask?.cancel()
        await uploadTask?.value
        allowSleep()
        log("recorder stopped")
    }

    /// The app saved cameras or settings: read the cameras and the storage again at the next tick.
    public func configurationChanged() {
        camerasLoaded = .distantPast
        storageStale = true
    }

    /// Starts, replaces or stops the uploader to match the storage setup.
    private func reloadStorage() async {
        storageStale = false
        let setup = loadStorage()
        guard setup?.fingerprint != storageFingerprint || (setup != nil) != (uploader != nil) else { return }
        uploadTask?.cancel()
        await uploadTask?.value
        uploadTask = nil
        uploader = nil
        storageFingerprint = setup?.fingerprint
        guard let setup else {
            log("no off-site storage set up: kept files stay on this Mac")
            return
        }
        let uploader = Uploader(root: directory, setup: setup, log: log)
        self.uploader = uploader
        let names = Dictionary(loadCameras().map { ($0.id, $0.name.isEmpty ? $0.host : $0.name) }, uniquingKeysWith: { a, _ in a })
        await uploader.enqueueLeftovers(cameraNames: names)
        let waiting = await uploader.pending
        log("uploading to \(setup.configuration.bucket) at \(setup.configuration.endpoint.host ?? "?")"
            + (waiting > 0 ? ", \(waiting) waiting" : ""))
        uploadTask = Task { await uploader.run() }
    }

    private func kept(_ kept: CameraRecorder.Kept, camera: RecorderCamera) async {
        await uploader?.enqueue(file: kept.url, camera: camera.id, cameraName: camera.name.isEmpty ? camera.host : camera.name,
                                start: kept.start, duration: kept.duration, motion: kept.motion)
    }

    private func tick(now: Date) async {
        if storageStale { await reloadStorage() }
        let settings = loadSettings()
        let active = settings.isActive(at: now)
        if active != wasActive {
            wasActive = active
            if active {
                log("window open: recording")
            } else if !settings.enabled {
                log("recording is switched off")
            } else if settings.window == nil {
                log("no recording window set")
            } else {
                log("window closed: idle")
            }
            camerasLoaded = .distantPast
        }
        if active {
            if now.timeIntervalSince(camerasLoaded) >= 60 {
                cameras = loadCameras().filter { !$0.host.isEmpty }
                camerasLoaded = now
            }
            preventSleep()
        } else if settings.isActive(at: now.addingTimeInterval(TimeInterval(PowerSchedule.leadSeconds) + 30)) {
            // The window opens in a moment, and the Mac may just have been woken for it.
            preventSleep()
        } else {
            allowSleep()
        }
        await reconcile(with: active ? cameras : [], parameters: settings.parameters)

        if now.timeIntervalSince(lastCleanup) >= 3600 {
            lastCleanup = now
            let removed = RecordingStore.removeExpired(in: directory, olderThan: settings.localCacheDays, now: now)
            if removed > 0 { log("removed \(removed) file\(removed == 1 ? "" : "s") older than \(settings.localCacheDays) days") }
        }
    }

    /// Brings the running recorders in line with `wanted`: stops those whose camera is gone or
    /// changed, or whose parameters changed, and starts the missing ones.
    private func reconcile(with wanted: [RecorderCamera], parameters: RecordingSettings.Parameters) async {
        for (id, entry) in running {
            let still = wanted.first { $0.id == id }
            if still != entry.camera || entry.parameters != parameters {
                running[id] = nil
                await entry.recorder.stop()
            }
        }
        for camera in wanted where running[camera.id] == nil {
            let log = self.log
            let name = camera.name.isEmpty ? camera.host : camera.name
            let recorder = CameraRecorder(camera: camera, parameters: parameters,
                                          directory: RecordingStore.directory(for: camera.id, in: directory),
                                          log: { log("[\(name)] \($0)") },
                                          onKept: { [weak self] kept in Task { await self?.kept(kept, camera: camera) } })
            running[camera.id] = Running(camera: camera, parameters: parameters, recorder: recorder)
            recorder.start()
        }
    }

    // The Mac may still be put to sleep by hand or by a closed lid; the recorders reconnect
    // when it wakes.
    private func preventSleep() {
        guard awake == nil else { return }
        awake = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled],
                                                      reason: "Recording the cameras")
    }

    private func allowSleep() {
        guard let token = awake else { return }
        awake = nil
        ProcessInfo.processInfo.endActivity(token)
    }
}
