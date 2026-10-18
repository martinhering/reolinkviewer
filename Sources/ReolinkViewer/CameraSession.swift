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
    @Published private(set) var frameSize: CGSize = .zero
    @Published private(set) var fps: Double = 0
    /// Infrared illuminator mode as last read from or written to the camera; nil until connected.
    @Published private(set) var infrared: InfraredMode?
    /// Day & Night image mode as last read from or written to the camera; nil until connected.
    @Published private(set) var dayNight: DayNightMode?
    @Published var streamKind: StreamKind = .main {
        didSet { if oldValue != streamKind { restartVideo() } }
    }
    @Published var settings: CameraSettings = SettingsStore.load()

    let renderer = VideoRenderer()
    let audio = AudioPlayer()
    /// Whether the camera's microphone is played back. Persisted.
    @Published var audioEnabled: Bool = UserDefaults.standard.object(forKey: "audioEnabled") == nil
        ? true : UserDefaults.standard.bool(forKey: "audioEnabled") {
        didSet {
            UserDefaults.standard.set(audioEnabled, forKey: "audioEnabled")
            audio.setEnabled(audioEnabled)
        }
    }
    /// Set REOLINK_DEBUG=1 to log connection and decoding progress to stderr.
    private let debug = ProcessInfo.processInfo.environment["REOLINK_DEBUG"] != nil

    private var camera: BaichuanCamera?
    private var runTask: Task<Void, Never>?
    private var consumerTask: Task<Void, Error>?
    private var ptzContinuation: AsyncStream<PTZDirection>.Continuation?
    private var ptzTask: Task<Void, Never>?
    private var activePTZ: PTZDirection?

    var isLive: Bool { state == .live }

    // MARK: Lifecycle

    /// (Re)starts the connection loop with the current settings.
    func start() {
        stop()
        guard settings.isComplete else {
            state = .idle
            statusText = "Enter the camera address and password in Settings (⌘,)"
            return
        }
        runTask = Task { await run() }
    }

    func stop() {
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

    func applySettings(_ s: CameraSettings) {
        settings = s
        SettingsStore.save(s)
        start()
    }

    private func run() async {
        var backoff: Double = 1
        while !Task.isCancelled {
            let cfg = settings
            let camera = BaichuanCamera(host: cfg.host, port: cfg.port, username: cfg.username, password: cfg.password)
            if debug { await camera.setLog { NSLog("camera: %@", $0) } }
            self.camera = camera
            state = .connecting
            statusText = "Connecting to \(cfg.host)…"
            do {
                let info = try await camera.connect()
                let enc = await camera.encryption?.name ?? ""
                deviceSummary = [info["type"], info["resolution.resolutionName"], enc].compactMap { $0 }.joined(separator: " · ")
                backoff = 1
                startPTZQueue(camera)
                infrared = try? await camera.getLEDState().infrared
                dayNight = try? await camera.getDayNightMode()
                if debug { NSLog("infrared: %@, day/night: %@", infrared?.rawValue ?? "unknown", dayNight?.rawValue ?? "unknown") }
                try await streamLoop(camera)
            } catch {
                if Task.isCancelled { break }
                if debug { NSLog("session error: %@", "\(error)") }
                state = .error("\(error)")
                statusText = "\(error)"
                fps = 0
            }
            await camera.disconnect()
            infrared = nil
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
                        if debug { NSLog("video: %.1f fps, %@ · %@", fps, renderer.statusDescription, audio.statusDescription) }
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
        guard direction != .stop, activePTZ != direction else { return }
        activePTZ = direction
        ptzContinuation?.yield(direction)
    }

    func ptzStop() {
        guard activePTZ != nil else { return }
        activePTZ = nil
        ptzContinuation?.yield(.stop)
    }
}
