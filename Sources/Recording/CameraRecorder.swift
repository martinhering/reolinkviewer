import Baichuan
import CameraMedia
import Foundation

/// What the recorder needs to know about a camera.
public struct RecorderCamera: Sendable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var host: String
    public var port: UInt16
    public var username: String
    public var password: String

    public init(id: UUID, name: String, host: String, port: UInt16 = 9000, username: String = "admin", password: String) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.password = password
    }
}

/// Records one camera for as long as it runs: holds its own connection, writes segment files,
/// follows the camera's motion, and keeps or deletes each segment once it can be judged.
///
/// Files are written to `<directory>/pending/…` and move to `<directory>/yyyy-MM-dd/…` when
/// they are kept, so the dated folders only ever hold kept segments.
public final class CameraRecorder: @unchecked Sendable {
    /// A segment that passed the keep rule.
    public struct Kept: Sendable {
        public let url: URL
        public let start: Date
        public let duration: TimeInterval
        /// The motion inside the segment.
        public let motion: [DateInterval]
    }

    /// Seconds without a frame after which the connection counts as dead.
    static let stallTimeout: TimeInterval = 10

    private let camera: RecorderCamera
    private let parameters: RecordingSettings.Parameters
    private let directory: URL
    private let forceFrameSizeDetection: Bool
    private let log: @Sendable (String) -> Void
    private let onKept: (@Sendable (Kept) -> Void)?
    private let lock = NSLock()
    private var task: Task<Void, Never>?

    /// - Parameters:
    ///   - directory: this camera's folder.
    ///   - forceFrameSizeDetection: judge motion by frame sizes even if the camera pushes events.
    public init(camera: RecorderCamera, parameters: RecordingSettings.Parameters, directory: URL,
                forceFrameSizeDetection: Bool = false, log: @escaping @Sendable (String) -> Void,
                onKept: (@Sendable (Kept) -> Void)? = nil) {
        self.camera = camera
        self.parameters = parameters
        self.directory = directory
        self.forceFrameSizeDetection = forceFrameSizeDetection
        self.log = log
        self.onKept = onKept
    }

    public func start() {
        lock.lock(); defer { lock.unlock() }
        guard task == nil else { return }
        task = Task { await self.run() }
    }

    /// Stops recording, closes the running file and judges everything still undecided.
    public func stop() async {
        let running = takeTask()
        running?.cancel()
        await running?.value
    }

    private func takeTask() -> Task<Void, Never>? {
        lock.lock(); defer { lock.unlock() }
        defer { task = nil }
        return task
    }

    static func pendingDirectory(in directory: URL) -> URL {
        directory.appendingPathComponent("pending", isDirectory: true)
    }

    private func run() async {
        let pending = Self.pendingDirectory(in: directory)
        // Whatever a crashed run left behind was never judged.
        try? FileManager.default.removeItem(at: pending)
        // A run that could not put the spotlight setting back left a note; honour it now if
        // the floodlight is no longer wanted.
        if !parameters.floodlight { await restoreFloodlight() }
        let motion = MotionState()
        var undecided: [SegmentRecorder.Segment] = []
        var backoff = 1.0

        while !Task.isCancelled {
            let client = BaichuanCamera(host: camera.host, port: camera.port, username: camera.username, password: camera.password)
            let recorder = SegmentRecorder(directory: pending, segmentLength: TimeInterval(parameters.segmentLength),
                                           recordAudio: parameters.audio)
            do {
                try await client.connect()
                await enableFloodlight(on: client)
                var detector: FrameSizeMotionDetector? = nil
                if forceFrameSizeDetection {
                    detector = FrameSizeMotionDetector()
                } else {
                    let log = self.log
                    await client.setMotionHandler { event in
                        if motion.report(event.isMotion, at: Date()) {
                            log(event.isMotion ? "motion" + (event.detectedObject.map { " (\($0))" } ?? "") : "motion ended")
                        }
                    }
                    do {
                        try await client.startMotionEvents()
                    } catch {
                        if Task.isCancelled { throw error }
                        detector = FrameSizeMotionDetector()
                    }
                }
                let frames = try await client.startVideo(parameters.stream)
                log("recording the \(parameters.stream == .main ? "Clear" : "Fluent") stream, motion from "
                    + (detector == nil ? "the camera's events" : "frame sizes"))
                backoff = 1

                let lastFrame = LastFrame()
                let watchdog = Task { [weak client] in
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(2))
                        if lastFrame.age > Self.stallTimeout {
                            await client?.disconnect()  // makes the frame loop throw, which reconnects
                            return
                        }
                    }
                }
                defer { watchdog.cancel() }
                for try await frame in frames {
                    let now = Date()
                    lastFrame.touch(now)
                    if detector != nil, let change = detector!.add(frame, at: now) {
                        motion.report(change, at: now)
                        log(change ? "motion (frame sizes)" : "motion ended")
                    }
                    if let closed = try await recorder.append(frame) { undecided.append(closed) }
                    judge(&undecided, motion: motion, now: now, force: false)
                }
                if !Task.isCancelled { log("the stream ended") }
            } catch {
                if !Task.isCancelled { log("\(error)") }
            }
            undecided += (try? await recorder.finish()) ?? []
            // Without a connection nothing is known about motion any more.
            motion.report(false, at: Date())
            await client.disconnect()
            if Task.isCancelled { break }
            judge(&undecided, motion: motion, now: Date(), force: false)
            try? await Task.sleep(for: .seconds(backoff))
            backoff = min(backoff * 2, 30)
        }
        judge(&undecided, motion: motion, now: Date(), force: true)
        // In a task of its own: this one is cancelled, and a cancelled task cannot wait for
        // the camera's answer.
        await Task { await self.restoreFloodlight() }.value
        log("stopped")
    }

    // MARK: Floodlight

    /// Holds the camera's own setting from before the recording period for as long as the
    /// recorder has changed it, so that it survives a crash.
    private var floodlightNote: URL { directory.appendingPathComponent("floodlight-before") }

    /// Makes the camera light its spotlight on motion in the dark, remembering how it was
    /// set. Does nothing for a camera without a spotlight.
    private func enableFloodlight(on client: BaichuanCamera) async {
        // A camera without a spotlight may still answer the settings request, so ask first.
        guard parameters.floodlight, await client.hasSpotlight(),
              let automatic = try? await client.getSpotlightAutomatic() else { return }
        let fm = FileManager.default
        if !fm.fileExists(atPath: floodlightNote.path) {
            guard !automatic else { return }  // already as wanted: nothing to put back later
            try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
            try? Data("0".utf8).write(to: floodlightNote)
        }
        guard !automatic else { return }
        do {
            try await client.setSpotlightAutomatic(true)
            log("smart floodlight switched on for the recording period")
        } catch {
            log("could not switch the smart floodlight on: \(error)")
        }
    }

    /// Puts the camera's spotlight setting back to what it was before the recording period.
    private func restoreFloodlight() async {
        let fm = FileManager.default
        guard fm.fileExists(atPath: floodlightNote.path) else { return }
        let client = BaichuanCamera(host: camera.host, port: camera.port, username: camera.username, password: camera.password)
        do {
            try await client.connect()
            try await client.setSpotlightAutomatic(false)
            try? fm.removeItem(at: floodlightNote)
            log("smart floodlight set back to off, as before recording")
        } catch {
            log("could not switch the smart floodlight off again, will retry at the next start: \(error)")
        }
        await client.disconnect()
    }

    /// Keeps or deletes every segment that can be judged: `paddingBefore` seconds after its
    /// end, since motion that starts until then still reaches back into it.
    private func judge(_ undecided: inout [SegmentRecorder.Segment], motion: MotionState, now: Date, force: Bool) {
        guard !undecided.isEmpty else { return }
        let before = TimeInterval(parameters.paddingBefore)
        let after = TimeInterval(parameters.paddingAfter)
        undecided.removeAll { segment in
            let span = DateInterval(start: segment.start, duration: segment.duration)
            guard force || now >= span.end.addingTimeInterval(before) else { return false }
            let name = segment.url.lastPathComponent
            if parameters.keep == .everything || motion.touches(span, before: before, after: after, now: now) {
                let day = segment.url.deletingLastPathComponent().lastPathComponent
                let target = directory.appendingPathComponent(day, isDirectory: true).appendingPathComponent(name)
                do {
                    try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try? FileManager.default.removeItem(at: target)
                    try FileManager.default.moveItem(at: segment.url, to: target)
                    let spans = motion.spans(in: span, now: now)
                    let seconds = spans.reduce(0) { $0 + $1.duration }
                    log(String(format: "kept %@/%@  %.0f s, %.1f MB, motion %.0f s", day, name, segment.duration,
                               Double(segment.bytes) / 1e6, seconds))
                    onKept?(Kept(url: target, start: segment.start, duration: segment.duration, motion: spans))
                } catch {
                    log("could not keep \(name): \(error.localizedDescription)")
                }
            } else {
                try? FileManager.default.removeItem(at: segment.url)
                log("deleted \(name)  no motion")
            }
            return true
        }
        if let earliest = undecided.map(\.start).min() ?? Optional(now) {
            motion.prune(before: earliest.addingTimeInterval(-after - 60))
        }
    }
}

/// The motion log, shared between the camera's event handler and the frame loop.
private final class MotionState: @unchecked Sendable {
    private let lock = NSLock()
    private var log = MotionLog()

    /// Returns whether the state changed.
    @discardableResult
    func report(_ motion: Bool, at date: Date) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let before = log.openSince != nil
        log.report(motion, at: date)
        return before != motion
    }

    func touches(_ segment: DateInterval, before: TimeInterval, after: TimeInterval, now: Date) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return log.touches(segment, before: before, after: after, now: now)
    }

    func spans(in segment: DateInterval, now: Date) -> [DateInterval] {
        lock.lock(); defer { lock.unlock() }
        return log.spans(in: segment, now: now)
    }

    func prune(before date: Date) {
        lock.lock(); defer { lock.unlock() }
        log.prune(before: date)
    }
}

/// When the last frame arrived, for the stall watchdog.
private final class LastFrame: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date()

    func touch(_ now: Date) {
        lock.lock(); defer { lock.unlock() }
        date = now
    }

    var age: TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return Date().timeIntervalSince(date)
    }
}
