import Baichuan
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: CameraStore

    var body: some View {
        Group {
            if store.cameras.isEmpty {
                noCameras
            } else if store.showsGrid {
                CameraGridView()
            } else if let session = store.selectedSession {
                SingleCameraView()
                    .environmentObject(session)
                    .id(session.settings.id)
            }
        }
        .background(Color.black)
        .frame(minWidth: 640, minHeight: 360)
        .navigationTitle(title)
        .onAppear { store.start() }
        .toolbar {
            if store.cameras.count > 1 {
                ToolbarItem(placement: .navigation) {
                    Picker("Camera", selection: cameraSelection) {
                        ForEach(store.cameras) { camera in
                            Text(camera.displayName).tag(camera.id)
                        }
                        Divider()
                        Text("All Cameras").tag(allCamerasTag)
                    }
                    .help("Choose the camera to view (⌘1 … ⌘9), or show all of them (⌘0)")
                }
            }
            if !store.showsGrid, let session = store.selectedSession {
                ToolbarItem(placement: .principal) {
                    Picker("Stream", selection: $store.streamKind) {
                        Text("Clear").tag(StreamKind.main)
                        Text("Fluent").tag(StreamKind.sub)
                    }
                    .pickerStyle(.segmented)
                    .help("Clear: full resolution main stream. Fluent: low-resolution sub stream.")
                }
                ToolbarItem {
                    Button {
                        store.audioEnabled.toggle()
                    } label: {
                        Label(store.audioEnabled ? "Mute" : "Unmute",
                              systemImage: store.audioEnabled ? "speaker.wave.2" : "speaker.slash")
                    }
                    .help(store.audioEnabled ? "Sound from the camera's microphone is on; click to mute"
                                             : "Muted; click to hear the camera's microphone")
                }
                ToolbarItem {
                    SpotlightButton(session: session)
                }
                ToolbarItem {
                    NightVisionMenu(session: session)
                }
            }
            if !store.cameras.isEmpty {
                ToolbarItem {
                    Button { store.reconnect() } label: { Label("Reconnect", systemImage: "arrow.clockwise") }
                        .help(store.showsGrid ? "Reconnect to all cameras" : "Reconnect to the camera")
                }
            }
            ToolbarItem {
                SettingsLink { Label("Settings", systemImage: "gearshape") }
            }
        }
    }

    private let allCamerasTag = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))

    /// The camera menu's selection: a camera id, or the all-zero id for the grid.
    private var cameraSelection: Binding<UUID> {
        Binding(
            get: { store.showsGrid ? allCamerasTag : (store.selectedID ?? allCamerasTag) },
            set: { id in
                if id == allCamerasTag { store.layout = .grid } else { store.show(id) }
            })
    }

    private var title: String {
        if store.cameras.isEmpty { return "Reolink Viewer" }
        if store.showsGrid { return "All Cameras" }
        return store.selectedCamera?.displayName ?? "Reolink Viewer"
    }

    private var noCameras: some View {
        VStack(spacing: 12) {
            Image(systemName: "video.slash").font(.largeTitle)
            Text("Add a camera in Settings (⌘,)").multilineTextAlignment(.center)
        }
        .foregroundStyle(.secondary)
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Switches the white spotlight. Shown only for cameras that have one.
struct SpotlightButton: View {
    @ObservedObject var session: CameraSession

    var body: some View {
        if session.hasSpotlight {
            Toggle(isOn: Binding(get: { session.spotlight }, set: { session.setSpotlight($0) })) {
                Label(session.spotlight ? "Spotlight off" : "Spotlight on",
                      systemImage: session.spotlight ? "lightbulb.fill" : "lightbulb")
            }
            .toggleStyle(.button)
            .help(session.spotlight ? "The spotlight is on; click to switch it off"
                                    : "Switch the camera's white spotlight on")
        }
    }
}

/// The Day & Night and infrared menu for one camera. A view of its own so it follows the
/// session's published state.
struct NightVisionMenu: View {
    @ObservedObject var session: CameraSession

    var body: some View {
        Menu {
            Section("Picture") {
                Picker("Day & Night", selection: dayNightBinding) {
                    Text("Auto").tag(DayNightMode.auto)
                    Text("Color").tag(DayNightMode.color)
                    Text("Black & White").tag(DayNightMode.blackAndWhite)
                }
                .pickerStyle(.inline)
            }
            Section("Infrared LEDs") {
                Picker("Infrared", selection: infraredBinding) {
                    Text("Auto").tag(InfraredMode.auto)
                    Text("On").tag(InfraredMode.on)
                    Text("Off").tag(InfraredMode.off)
                }
                .pickerStyle(.inline)
            }
        } label: {
            Label("Night vision", systemImage: nightVisionSymbol)
        }
        .disabled(session.infrared == nil && session.dayNight == nil)
        .help("Picture: \(session.dayNight?.label ?? "unknown") · Infrared LEDs: \(session.infrared?.label ?? "unknown")")
    }

    private var infraredBinding: Binding<InfraredMode> {
        Binding(get: { session.infrared ?? .auto }, set: { session.setInfrared($0) })
    }

    private var dayNightBinding: Binding<DayNightMode> {
        Binding(get: { session.dayNight ?? .auto }, set: { session.setDayNight($0) })
    }

    private var nightVisionSymbol: String {
        session.dayNight == .auto && session.infrared == .auto ? "moon" : "moon.fill"
    }
}

/// One camera filling the window, with the pan/tilt pad and status badge over the picture.
struct SingleCameraView: View {
    @EnvironmentObject private var session: CameraSession
    @FocusState private var focused: Bool
    /// Centre of the pan/tilt pad as a fraction of the view size; negative = default (bottom right).
    @AppStorage("ptzPadX") private var padFractionX: Double = -1
    @AppStorage("ptzPadY") private var padFractionY: Double = -1
    @State private var padDragOrigin: CGPoint?

    var body: some View {
        ZStack {
            VideoView(renderer: session.renderer)
            if !session.isLive { placeholder }
            VStack {
                Spacer()
                HStack {
                    statusBadge
                    Spacer()
                }
                .padding(16)
            }
        }
        .overlay {
            if session.supportsPTZ {
                GeometryReader { geo in
                    PTZPad(
                        onDrag: { value in movePad(by: value.translation, in: geo.size) },
                        onDragEnd: { padDragOrigin = nil },
                        onReset: { padFractionX = -1; padFractionY = -1 }
                    )
                    .position(padCenter(in: geo.size))
                }
            }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(phases: [.down, .up], action: handleKey)
        .onAppear { focused = true }
    }

    // MARK: Pan/tilt pad placement

    private static let padSize = CGSize(width: 156, height: 156)
    private static let padMargin: CGFloat = 16

    private func clampedPadCenter(_ p: CGPoint, in size: CGSize) -> CGPoint {
        let hw = Self.padSize.width / 2, hh = Self.padSize.height / 2
        return CGPoint(x: min(max(p.x, hw), max(hw, size.width - hw)),
                       y: min(max(p.y, hh), max(hh, size.height - hh)))
    }

    private func padCenter(in size: CGSize) -> CGPoint {
        let p: CGPoint
        if padFractionX < 0 || padFractionY < 0 {
            p = CGPoint(x: size.width - Self.padMargin - Self.padSize.width / 2,
                        y: size.height - Self.padMargin - Self.padSize.height / 2)
        } else {
            p = CGPoint(x: padFractionX * size.width, y: padFractionY * size.height)
        }
        return clampedPadCenter(p, in: size)
    }

    private func movePad(by translation: CGSize, in size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        let origin = padDragOrigin ?? padCenter(in: size)
        padDragOrigin = origin
        let p = clampedPadCenter(CGPoint(x: origin.x + translation.width, y: origin.y + translation.height), in: size)
        padFractionX = p.x / size.width
        padFractionY = p.y / size.height
    }

    private var placeholder: some View {
        VStack(spacing: 12) {
            if case .error(let message) = session.state {
                Image(systemName: "exclamationmark.triangle").font(.largeTitle)
                Text(message).multilineTextAlignment(.center)
            } else if session.state == .connecting {
                ProgressView()
                Text(session.statusText)
            } else {
                Image(systemName: "video.slash").font(.largeTitle)
                Text(session.statusText).multilineTextAlignment(.center)
            }
        }
        .foregroundStyle(.secondary)
        .padding(32)
    }

    private var statusBadge: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Circle().fill(session.isLive ? Color.green : Color.orange).frame(width: 8, height: 8)
                Text(session.statusText).lineLimit(1)
            }
            if session.isLive {
                Text(liveDetail).font(.caption).foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
        .frame(maxWidth: 420, alignment: .leading)
    }

    private var liveDetail: String {
        var parts: [String] = []
        if session.frameSize != .zero { parts.append("\(Int(session.frameSize.width))×\(Int(session.frameSize.height))") }
        if session.fps > 0 { parts.append(String(format: "%.0f fps", session.fps)) }
        if !session.deviceSummary.isEmpty { parts.append(session.deviceSummary) }
        return parts.joined(separator: " · ")
    }

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        guard session.supportsPTZ else { return .ignored }
        let direction: PTZDirection
        switch press.key {
        case .leftArrow: direction = .left
        case .rightArrow: direction = .right
        case .upArrow: direction = .up
        case .downArrow: direction = .down
        default: return .ignored
        }
        switch press.phase {
        case .down: session.ptzStart(direction)
        case .up: session.ptzStop()
        default: break
        }
        return .handled
    }
}

/// Every camera at once, on the sub stream and muted. Clicking a tile opens that camera.
struct CameraGridView: View {
    @EnvironmentObject private var store: CameraStore
    private let spacing: CGFloat = 4

    var body: some View {
        GeometryReader { geo in
            let count = store.cameras.count
            let columns = max(1, Int(Double(count).squareRoot().rounded(.up)))
            let rows = (count + columns - 1) / columns
            let maxWidth = (geo.size.width - spacing * CGFloat(columns - 1)) / CGFloat(columns)
            let maxHeight = (geo.size.height - spacing * CGFloat(rows - 1)) / CGFloat(rows)
            let width = max(1, min(maxWidth, maxHeight * 16 / 9))
            let height = width * 9 / 16
            VStack(spacing: spacing) {
                ForEach(0..<rows, id: \.self) { row in
                    HStack(spacing: spacing) {
                        ForEach(store.cameras.dropFirst(row * columns).prefix(columns)) { camera in
                            if let session = store.session(for: camera) {
                                CameraTile(session: session, name: camera.displayName) { store.show(camera.id) }
                                    .frame(width: width, height: height)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct CameraTile: View {
    @ObservedObject var session: CameraSession
    let name: String
    let onSelect: () -> Void

    var body: some View {
        ZStack {
            VideoView(renderer: session.renderer)
            if !session.isLive {
                VStack(spacing: 8) {
                    if session.state == .connecting {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "video.slash").font(.title)
                    }
                    Text(session.statusText).font(.caption).multilineTextAlignment(.center).lineLimit(3)
                }
                .foregroundStyle(.secondary)
                .padding(16)
            }
            VStack {
                HStack(spacing: 6) {
                    Circle().fill(session.isLive ? Color.green : Color.orange).frame(width: 8, height: 8)
                    Text(name).lineLimit(1)
                }
                .font(.callout)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                Spacer()
            }
        }
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .contentShape(Rectangle())
        .onTapGesture { onSelect() }
        .help("Click to view \(name) on its own")
    }
}

/// Four press-and-hold arrows around a grip. The camera moves while a button (or arrow key)
/// is held; dragging the grip moves the pad itself, and its context menu resets the position.
struct PTZPad: View {
    @EnvironmentObject private var session: CameraSession
    let onDrag: (DragGesture.Value) -> Void
    let onDragEnd: () -> Void
    let onReset: () -> Void

    var body: some View {
        Grid(horizontalSpacing: 4, verticalSpacing: 4) {
            GridRow {
                Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                HoldButton(symbol: "chevron.up", direction: .up)
                Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
            }
            GridRow {
                HoldButton(symbol: "chevron.left", direction: .left)
                grip
                HoldButton(symbol: "chevron.right", direction: .right)
            }
            GridRow {
                Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                HoldButton(symbol: "chevron.down", direction: .down)
                Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
            }
        }
        .padding(8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .opacity(session.isLive ? 1 : 0.5)
    }

    private var grip: some View {
        Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
            .font(.body)
            .foregroundStyle(.secondary)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 2, coordinateSpace: .global)
                    .onChanged(onDrag)
                    .onEnded { _ in onDragEnd() }
            )
            .contextMenu {
                Button("Reset Position", action: onReset)
            }
            .help("Drag to move the pan/tilt controls")
    }
}

struct HoldButton: View {
    @EnvironmentObject private var session: CameraSession
    let symbol: String
    let direction: PTZDirection
    @State private var pressed = false

    var body: some View {
        Image(systemName: symbol)
            .font(.title2.weight(.semibold))
            .frame(width: 44, height: 44)
            .background(pressed ? Color.accentColor.opacity(0.6) : Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
            .opacity(session.isLive ? 1 : 0.6)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if !pressed && session.isLive {
                            pressed = true
                            session.ptzStart(direction)
                        }
                    }
                    .onEnded { _ in
                        pressed = false
                        session.ptzStop()
                    }
            )
            .help("Hold to move \(direction.rawValue); arrow keys work too")
    }
}


extension DayNightMode {
    var label: String {
        switch self {
        case .auto: return "Auto"
        case .color: return "Color"
        case .blackAndWhite: return "Black & White"
        }
    }
}

extension InfraredMode {
    var label: String {
        switch self {
        case .auto: return "Auto"
        case .on: return "On"
        case .off: return "Off"
        }
    }
}
