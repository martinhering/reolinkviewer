import Baichuan
import Foundation
import SwiftUI

/// The list of configured cameras, one `CameraSession` per camera, and which of them are
/// shown: a single camera with its controls, or all of them in a grid.
@MainActor
final class CameraStore: ObservableObject {
    enum Layout: String {
        case single, grid
    }

    @Published private(set) var cameras: [CameraSettings]
    @Published private(set) var sessions: [UUID: CameraSession] = [:]
    @Published var selectedID: UUID? {
        didSet {
            guard oldValue != selectedID else { return }
            defaults.set(selectedID?.uuidString, forKey: "selectedCamera")
            reconcile()
        }
    }
    @Published var layout: Layout {
        didSet {
            guard oldValue != layout else { return }
            defaults.set(layout.rawValue, forKey: "layout")
            reconcile()
        }
    }
    /// Stream shown in both the single-camera view and the grid.
    @Published var streamKind: StreamKind = .main {
        didSet { if oldValue != streamKind { reconcile() } }
    }
    /// The user's mute switch. Persisted.
    @Published var audioEnabled: Bool {
        didSet {
            defaults.set(audioEnabled, forKey: "audioEnabled")
            reconcile()
        }
    }

    /// The one camera heard in the grid, if any. The others stay muted so they do not talk
    /// over each other. Not persisted.
    @Published var gridAudioID: UUID? {
        didSet { if oldValue != gridAudioID { reconcile() } }
    }

    private let defaults = UserDefaults.standard
    private var started = false

    init() {
        let cameras = SettingsStore.load()
        self.cameras = cameras
        let defaults = UserDefaults.standard
        let saved = defaults.string(forKey: "selectedCamera").flatMap(UUID.init(uuidString:))
        _selectedID = Published(initialValue: cameras.first { $0.id == saved }?.id ?? cameras.first?.id)
        let savedLayout = Layout(rawValue: defaults.string(forKey: "layout") ?? "") ?? .single
        _layout = Published(initialValue: cameras.count < 2 ? .single : savedLayout)
        _audioEnabled = Published(initialValue: defaults.object(forKey: "audioEnabled") == nil ? true
                                                : defaults.bool(forKey: "audioEnabled"))
        for camera in cameras { sessions[camera.id] = CameraSession(settings: camera) }
    }

    var selectedCamera: CameraSettings? { cameras.first { $0.id == selectedID } }
    var selectedSession: CameraSession? { selectedID.flatMap { sessions[$0] } }
    var showsGrid: Bool { layout == .grid && cameras.count > 1 }

    func session(for camera: CameraSettings) -> CameraSession? { sessions[camera.id] }

    // MARK: Lifecycle

    /// Starts the sessions that the current layout shows. Called once the window is up.
    func start() {
        started = true
        reconcile()
    }

    /// Reconnects every camera on screen.
    func reconnect() {
        for session in sessions.values where session.isStarted { session.start() }
    }

    /// Stores a new camera list and brings the sessions in line with it.
    func apply(_ newCameras: [CameraSettings]) {
        SettingsStore.save(newCameras)
        for old in cameras where !newCameras.contains(where: { $0.id == old.id }) {
            sessions[old.id]?.stop()
            sessions[old.id] = nil
        }
        for camera in newCameras {
            if let session = sessions[camera.id] {
                if session.settings != camera { session.applySettings(camera) }
            } else {
                sessions[camera.id] = CameraSession(settings: camera)
            }
        }
        cameras = newCameras
        if selectedCamera == nil { selectedID = cameras.first?.id }
        if cameras.count < 2 { layout = .single }
        reconcile()
    }

    /// Records a password already changed on the camera itself. Only that camera's stored
    /// password changes; other unsaved edits in Settings are left alone.
    func passwordChanged(on id: UUID, to password: String) {
        var list = cameras
        guard let i = list.firstIndex(where: { $0.id == id }) else { return }
        list[i].password = password
        apply(list)
    }

    /// Writes `name` into the camera's picture (its OSD channel name), using the running
    /// session's connection if there is one, else a short-lived one.
    func writeNameToCamera(_ camera: CameraSettings, name: String) async throws {
        let client = BaichuanCamera(host: camera.host, port: camera.port, username: camera.username, password: camera.password)
        try await client.connect()
        defer { Task { await client.disconnect() } }
        try await client.setOSDName(name)
    }

    // MARK: Selection

    /// Shows `id` on its own, leaving the grid if needed.
    func show(_ id: UUID) {
        selectedID = id
        layout = .single
    }

    func selectNext() { step(by: 1) }
    func selectPrevious() { step(by: -1) }

    private func step(by offset: Int) {
        guard !cameras.isEmpty else { return }
        let index = cameras.firstIndex { $0.id == selectedID } ?? 0
        show(cameras[(index + offset + cameras.count) % cameras.count].id)
    }

    /// Runs exactly the sessions the layout shows, all with the chosen stream: every camera in
    /// the grid (only `gridAudioID` audible), otherwise only the selected one (with the mute switch).
    private func reconcile() {
        guard started else { return }
        let grid = showsGrid
        for camera in cameras {
            guard let session = sessions[camera.id] else { continue }
            if grid || camera.id == selectedID {
                session.streamKind = streamKind
                session.audioEnabled = grid ? camera.id == gridAudioID : audioEnabled
                if !session.isStarted { session.start() }
            } else if session.isStarted {
                session.stop()
            }
        }
    }
}
