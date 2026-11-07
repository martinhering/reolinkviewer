import Baichuan
import Foundation
import SwiftUI

/// Owns the camera connection, keeps it alive, and drives the video renderer.
@MainActor
final class CameraSession: ObservableObject {
    enum State: Equatable {
        case idle, connecting, live, error(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var statusText = "Not connected"
    @Published private(set) var deviceSummary = ""
    /// False once the camera reports `ptzMode = none` (a fixed camera); such cameras reject
    /// PTZ commands with code 400.
    @Published private(set) var supportsPTZ = true
    @Published private(set) var frameSize: CGSize = .zero
    @Published private(set) var fps: Double = 0
    /// Infrared illuminator mode as last read from or written to the camera; nil until connected.
    @Published private(set) var infrared: InfraredMode?
    /// True once the camera has answered the spotlight probe; false for cameras without one.
    @Published private(set) var hasSpotlight = false
    /// Whether the white spotlight is on, as last switched or reported by the camera.
    @Published private(set) var spotlight = false
    /// Day & Night image mode as last read from or written to the camera; nil until connected.
    @Published private(set) var dayNight: DayNightMode?
    @Published var streamKind: StreamKind = .main {
        didSet { if oldValue != streamKind { restartVideo() } }
    }
    @Published private(set) var settings: CameraSettings

    let renderer = VideoRenderer()
    let audio = AudioPlayer()
    /// Whether the camera's microphone is played back. The store decides: the user's mute
    /// switch, and never in the grid.
    @Published var audioEnabled = true {
        didSet { audio.setEnabled(audioEnabled) }
    }
    /// True between `start()` and `stop()`, whether or not the connection is up.
    private(set) var isStarted = false
    /// Set REOLINK_DEBUG=1 to log connection and decoding progress to stderr.
    private let debug = ProcessInfo.processInfo.environment["REOLINK_DEBUG"] != nil

    private var camera: BaichuanCamera?
    private var runTask: Task<Void, Never>?
    private var consumerTask: Task<Void, Error>?
    private var ptzContinuation: AsyncStream<PTZDirection>.Continuation?
    private var ptzTask: Task<Void, Never>?
    private var activePTZ: PTZDirection?

    var isLive: Bool { state == .live }

    init(settings: CameraSettings) {
        self.settings = settings
    }

    // MARK: Lifecycle

    /// (Re)starts the connection loop with the current settings.
    func start() {
        stop()
        isStarted = true
        guard settings.isComplete else {
            state = .idle
            statusText = "Enter the camera address and username in Settings (⌘,)"
            return
        }
        runTask = Task { await run() }
    }

    func stop() {
        isStarted = false
        spotlightRefresh?.cancel()
        spotlightRefresh = nil
        audio.reset()
        runTask?.cancel()
        runTask = nil
        consumerTask?.cancel()
        consumerTask = nil
        ptzTask?.cancel()
        ptzTask = nil
        ptzContinuation?.finish()
        ptzContinuation = nil
        let old = camera
        camera = nil
        Task { await old?.disconnect() }
        state = .idle
        statusText = "Not connected"
        fps = 0
    }

    /// Takes new settings; reconnects if the session is running.
    func applySettings(_ s: CameraSettings) {
        settings = s
        if isStarted { start() }
    }

    private func run() async {
        var backoff: Double = 1
        while !Task.isCancelled {
            let cfg = settings
            let camera = BaichuanCamera(host: cfg.host, port: cfg.port, username: cfg.username, password: cfg.password)
            let name = cfg.displayName
            if debug { await camera.setLog { NSLog("[%@] camera: %@", name, $0) } }
            self.camera = camera
            state = .connecting
            statusText = "Connecting to \(cfg.host)…"
            do {
                let info = try await camera.connect()
                let enc = await camera.encryption?.name ?? ""
                deviceSummary = [info["type"], info["resolution.resolutionName"], enc].compactMap { $0 }.joined(separator: " · ")
                supportsPTZ = info["ptzMode"] != "none"
                backoff = 1
                if supportsPTZ { startPTZQueue(camera) }
                infrared = try? await camera.getLEDState().infrared
                hasSpotlight = await camera.hasSpotlight()
                if hasSpotlight {
                    spotlight = await camera.spotlightState ?? false
                    await camera.setSpotlightHandler { [weak self] on in
                        Task { @MainActor in self?.spotlightReported(on) }
                    }
                }
                dayNight = try? await camera.getDayNightMode()
                if debug { NSLog("[%@] infrared: %@, day/night: %@", cfg.displayName, infrared?.rawValue ?? "unknown", dayNight?.rawValue ?? "unknown") }
                try await streamLoop(camera)
            } catch {
                if Task.isCancelled { break }
                if debug { NSLog("[%@] session error: %@", cfg.displayName, "\(error)") }
                state = .error("\(error)")
                statusText = "\(error)"
                fps = 0
            }
            await camera.disconnect()
            infrared = nil
            hasSpotlight = false
            spotlight = false
            spotlightRefresh?.cancel()
            spotlightRefresh = nil
            dayNight = nil
            if Task.isCancelled { break }
            statusText += " · retrying in \(Int(backoff)) s"
            try? await Task.sleep(for: .seconds(backoff))
            backoff = min(backoff * 2, 10)
        }
    }

    /// Streams until the connection fails (throws) or the task is cancelled. A change of stream
    /// kind cancels only the consumer, so the loop restarts the video on the same connection.
    private func streamLoop(_ camera: BaichuanCamera) async throws {
        while !Task.isCancelled {
            let kind = streamKind
            let frames = try await camera.startVideo(kind)
            state = .live
            statusText = "Live · \(kind == .main ? "Clear" : "Fluent")"
            let renderer = self.renderer
            let audio = self.audio
            audio.setEnabled(audioEnabled)
            let debug = self.debug
            let name = settings.displayName
            let consumer = Task.detached(priority: .userInitiated) {
                renderer.reset()
                audio.reset()
                var lastReport = Date()
                var framesAtReport = renderer.framesEnqueued
                for try await frame in frames {
                    if case .aac(let data) = frame {
                        audio.enqueue(adts: data)
                    } else {
                        renderer.enqueue(frame)
                    }
                    let now = Date()
                    if now.timeIntervalSince(lastReport) >= 1 {
                        let count = renderer.framesEnqueued
                        let fps = Double(count - framesAtReport) / now.timeIntervalSince(lastReport)
                        let size = renderer.frameSize
                        lastReport = now
                        framesAtReport = count
                        if debug { NSLog("[%@] video: %.1f fps, %@ · %@", name, fps, renderer.statusDescription, audio.statusDescription) }
                        await MainActor.run { self.fps = fps; self.frameSize = size }
                    }
                }
            }
            consumerTask = consumer
            let watchdog = Task { [weak camera] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(2))
                    if let last = renderer.lastFrameTime, Date().timeIntervalSince(last) > 10 {
                        await camera?.disconnect()  // makes the consumer throw, which reconnects
                        return
                    }
                }
            }
            defer { watchdog.cancel() }
            try await consumer.value  // throws when the connection drops
            if Task.isCancelled { break }
            // Stream kind changed: the camera actor stops the old stream when the next one starts.
            fps = 0
        }
    }

    private func restartVideo() {
        consumerTask?.cancel()
    }

    // MARK: Infrared

    func setInfrared(_ mode: InfraredMode) {
        guard let camera, mode != infrared else { return }
        let previous = infrared
        infrared = mode
        Task {
            do {
                try await camera.setInfrared(mode)
            } catch {
                infrared = previous
                statusText = "Infrared: \(error)"
            }
        }
    }

    // MARK: Spotlight

    /// How long each "on" command holds, and how often it is renewed while the switch is on.
    private static let spotlightHold: UInt16 = 180
    private static let spotlightRenewal: Duration = .seconds(120)
    private var spotlightRefresh: Task<Void, Never>?

    /// The camera only keeps a manual "on" for a while, so the session renews it until the
    /// user switches the light off (or leaves this camera).
    func setSpotlight(_ on: Bool) {
        guard let camera, hasSpotlight, on != spotlight else { return }
        spotlight = on
        spotlightRefresh?.cancel()
        spotlightRefresh = nil
        Task { [weak self] in
            do {
                try await camera.setSpotlight(on, duration: Self.spotlightHold)
            } catch {
                self?.spotlight = !on
                self?.statusText = "Spotlight: \(error)"
                return
            }
            guard let self, on, self.spotlight else { return }
            self.spotlightRefresh?.cancel()
            self.spotlightRefresh = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: Self.spotlightRenewal)
                    guard !Task.isCancelled, let self, self.spotlight else { return }
                    try? await camera.setSpotlight(true, duration: Self.spotlightHold)
                }
            }
        }
    }

    /// The camera's own report. "Off" while the switch is on means someone else turned it
    /// off (the renewal keeps a manual "on" from running out), so the switch follows.
    private func spotlightReported(_ on: Bool) {
        if !on {
            spotlightRefresh?.cancel()
            spotlightRefresh = nil
        }
        spotlight = on
    }

    func setDayNight(_ mode: DayNightMode) {
        guard let camera, mode != dayNight else { return }
        let previous = dayNight
        dayNight = mode
        Task {
            do {
                try await camera.setDayNightMode(mode)
            } catch {
                dayNight = previous
                statusText = "Day & Night: \(error)"
            }
        }
    }

    // MARK: PTZ

    private func startPTZQueue(_ camera: BaichuanCamera) {
        ptzTask?.cancel()
        let (stream, continuation) = AsyncStream<PTZDirection>.makeStream(bufferingPolicy: .unbounded)
        ptzContinuation = continuation
        let speed = settings.ptzSpeed
        ptzTask = Task.detached {
            for await direction in stream {
                do {
                    try await camera.ptz(direction, speed: speed)
                } catch {
                    NSLog("PTZ \(direction) failed: \(error)")
                }
            }
        }
    }

    func ptzStart(_ direction: PTZDirection) {
        guard supportsPTZ, direction != .stop, activePTZ != direction else { return }
        activePTZ = direction
        ptzContinuation?.yield(direction)
    }

    func ptzStop() {
        guard activePTZ != nil else { return }
        activePTZ = nil
        ptzContinuation?.yield(.stop)
    }
}
