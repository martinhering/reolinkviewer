import AVFoundation
import AppKit
import Recording
import SwiftUI

/// The Recordings window: one camera or all cameras in step, over a timeline of the day.
struct RecordingsView: View {
    @EnvironmentObject private var store: CameraStore
    @StateObject private var playback = PlaybackController()
    @State private var settingUpKey = false

    private let allCamerasTag = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))

    var body: some View {
        VStack(spacing: 0) {
            picture
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.black)
            Divider()
            transport
            Divider()
            RecordingTimeline(playback: playback)
        }
        .frame(minWidth: 760, minHeight: 520)
        .onAppear { playback.start(order: store.cameras.map(\.id)) }
        .onDisappear { playback.stop() }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                DatePicker("Day", selection: Binding(get: { playback.day }, set: { playback.show(day: $0) }),
                           in: ...Date(), displayedComponents: .date)
                    .labelsHidden()
                    .help("The day to play")
            }
            ToolbarItem(placement: .navigation) {
                Picker("Camera", selection: cameraSelection) {
                    ForEach(playback.recordings.cameras) { camera in
                        Text(camera.name).tag(camera.id)
                    }
                    if playback.recordings.cameras.count > 1 {
                        Divider()
                        Text("All Cameras").tag(allCamerasTag)
                    }
                }
                .help("One camera, or all of them in step")
                .disabled(playback.recordings.isEmpty)
            }
            ToolbarItem {
                Button { settingUpKey = true } label: { Label("Playback Key", systemImage: "key") }
                    .help(playback.canDownload ? "Change the key that downloads recordings from the bucket"
                                               : "Set a read-only key to play recordings that are no longer on this Mac")
            }
            ToolbarItem {
                Button { playback.show(day: playback.day, keepPlayhead: true) } label: { Label("Reload", systemImage: "arrow.clockwise") }
                    .help("Read the day's recordings again")
            }
        }
        .sheet(isPresented: $settingUpKey) {
            PlaybackKeyView {
                settingUpKey = false
                playback.openLibrary()
            }
        }
    }

    private var cameraSelection: Binding<UUID> {
        Binding(
            get: { playback.layout == .grid ? allCamerasTag : (playback.selectedCamera ?? allCamerasTag) },
            set: { id in
                if id == allCamerasTag {
                    playback.layout = .grid
                } else {
                    playback.showAlone(id)
                }
            })
    }

    // MARK: Picture

    @ViewBuilder
    private var picture: some View {
        if let message = playback.message, playback.recordings.isEmpty {
            Text(message).foregroundStyle(.secondary).padding()
        } else if playback.isLoadingDay && playback.recordings.isEmpty {
            ProgressView()
        } else if playback.layout == .grid {
            grid
        } else if let id = playback.shownCameras.first, let player = playback.players[id] {
            ClipTile(player: player, name: nil, hasClip: playback.visibleCameras.contains(id))
        }
    }

    private var grid: some View {
        GeometryReader { geometry in
            let ids = playback.visibleCameras
            if ids.isEmpty {
                Text("No camera has a recording at this time.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                let columns = Self.columns(for: ids.count, in: geometry.size)
                let rows = Int((Double(ids.count) / Double(columns)).rounded(.up))
                let width = geometry.size.width / CGFloat(columns)
                let height = geometry.size.height / CGFloat(rows)
                VStack(spacing: 0) {
                    ForEach(0..<rows, id: \.self) { row in
                        HStack(spacing: 0) {
                            ForEach(ids.dropFirst(row * columns).prefix(columns), id: \.self) { id in
                                if let player = playback.players[id] {
                                    ClipTile(player: player, name: name(of: id), hasClip: true,
                                             audible: playback.audibleCamera == id,
                                             onAudio: { playback.audibleCamera = playback.audibleCamera == id ? nil : id },
                                             onOpen: { playback.showAlone(id) })
                                        .frame(width: width, height: height)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    /// The column count that gives 16:9 tiles the most room.
    static func columns(for count: Int, in size: CGSize) -> Int {
        guard count > 1, size.width > 0, size.height > 0 else { return 1 }
        var best = 1
        var bestArea: CGFloat = 0
        for columns in 1...count {
            let rows = Int((Double(count) / Double(columns)).rounded(.up))
            let width = size.width / CGFloat(columns), height = size.height / CGFloat(rows)
            let tileWidth = min(width, height * 16 / 9)
            if tileWidth > bestArea {
                bestArea = tileWidth
                best = columns
            }
        }
        return best
    }

    private func name(of id: UUID) -> String {
        playback.recordings.cameras.first { $0.id == id }?.name ?? ""
    }

    // MARK: Transport

    private var transport: some View {
        HStack(spacing: 12) {
            Button { playback.skip(forward: false) } label: { Image(systemName: "backward.end.fill") }
                .help("Previous recording")
            Button { playback.togglePlay() } label: {
                Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill").frame(width: 16)
            }
            .keyboardShortcut(.space, modifiers: [])
            .help(playback.isPlaying ? "Pause" : "Play")
            Button { playback.skip(forward: true) } label: { Image(systemName: "forward.end.fill") }
                .help("Next recording")

            Text(Self.clock.string(from: playback.playhead))
                .font(.system(.body, design: .monospaced))
                .frame(minWidth: 80, alignment: .leading)

            Picker("Speed", selection: $playback.rate) {
                ForEach(PlaybackController.rates, id: \.self) { rate in
                    Text("\(Int(rate))×").tag(rate)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 150)
            .help("Playback speed; above 2× without sound")

            Spacer()

            if let message = playback.message, !playback.recordings.isEmpty {
                Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }

            Picker("Timeline", selection: $playback.timelineSpan) {
                Text("24 h").tag(TimeInterval(86400))
                Text("6 h").tag(TimeInterval(21600))
                Text("1 h").tag(TimeInterval(3600))
                Text("10 min").tag(TimeInterval(600))
            }
            .labelsHidden()
            .frame(width: 90)
            .help("How much of the day the timeline shows")

            if playback.layout == .single {
                Toggle(isOn: Binding(get: { !playback.muted }, set: { playback.muted = !$0 })) {
                    Image(systemName: playback.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                }
                .toggleStyle(.button)
                .help(playback.muted ? "Sound is off" : "Sound is on")
                Button { saveClip() } label: { Image(systemName: "square.and.arrow.down") }
                    .help("Save the recording under the playhead as an MP4 file")
                    .disabled(playback.currentClipForSaving() == nil)
            }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .disabled(playback.recordings.isEmpty)
    }

    static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private func saveClip() {
        guard let (clip, data) = playback.currentClipForSaving() else { return }
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = "\(name(of: clip.camera)) \(stamp.string(from: clip.start)).mp4"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url)
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}

/// One camera's picture, with its name and controls when it is a grid tile.
struct ClipTile: View {
    @ObservedObject var player: ClipPlayer
    let name: String?
    let hasClip: Bool
    var audible = false
    var onAudio: (() -> Void)?
    var onOpen: (() -> Void)?

    var body: some View {
        ZStack {
            PlayerLayerView(player: player.player)
            if let failure = player.failure {
                Text(failure).font(.caption).foregroundStyle(.white).multilineTextAlignment(.center).padding()
            } else if player.isLoading {
                ProgressView().controlSize(.small).colorScheme(.dark)
            } else if !hasClip {
                Text("No recording at this time.").foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { onOpen?() }
        .overlay(alignment: .topLeading) {
            if let name {
                Text(name)
                    .font(.caption.weight(.semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 5))
                    .padding(6)
            }
        }
        .overlay(alignment: .topTrailing) {
            if let onAudio {
                Button(action: onAudio) {
                    Image(systemName: audible ? "speaker.wave.2.fill" : "speaker.slash.fill")
                        .foregroundStyle(.white)
                        .padding(5)
                        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)
                .padding(6)
                .help(audible ? "This camera is heard" : "Hear this camera")
            }
        }
        .border(Color.black, width: name == nil ? 0 : 0.5)
    }
}

/// Hosts an AVPlayerLayer.
struct PlayerLayerView: NSViewRepresentable {
    let player: AVPlayer

    final class HostView: NSView {
        let playerLayer = AVPlayerLayer()

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer = CALayer()
            layer?.backgroundColor = CGColor(gray: 0, alpha: 1)
            playerLayer.videoGravity = .resizeAspect
            layer?.addSublayer(playerLayer)
        }

        required init?(coder: NSCoder) { fatalError("not used") }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            playerLayer.frame = bounds
            CATransaction.commit()
        }
    }

    func makeNSView(context: Context) -> HostView {
        let view = HostView()
        view.playerLayer.player = player
        return view
    }

    func updateNSView(_ view: HostView, context: Context) {
        if view.playerLayer.player !== player { view.playerLayer.player = player }
    }
}

/// The day as lanes, one per shown camera: recorded minutes as blocks, motion marked, and the
/// playhead. Click or drag to move the playhead.
struct RecordingTimeline: View {
    @ObservedObject var playback: PlaybackController
    /// The window's start while dragging, so that it does not slide under the pointer.
    @State private var dragStart: Date?

    private let laneHeight: CGFloat = 16
    private let laneGap: CGFloat = 4
    private let axisHeight: CGFloat = 18
    private let labelWidth: CGFloat = 96

    private var lanes: [Recordings.Camera] {
        let shown = Set(playback.shownCameras)
        return playback.recordings.cameras.filter { shown.contains($0.id) }
    }

    /// The part of the day on screen: all of it, or a window that follows the playhead.
    private var windowStart: Date {
        if let dragStart { return dragStart }
        let day = playback.daySpan
        let span = min(playback.timelineSpan, day.duration)
        let wanted = playback.playhead.addingTimeInterval(-span / 2)
        return min(max(wanted, day.start), day.end.addingTimeInterval(-span))
    }

    var body: some View {
        let lanes = self.lanes
        let height = axisHeight + CGFloat(max(lanes.count, 1)) * (laneHeight + laneGap) + 6
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: laneGap) {
                Color.clear.frame(height: axisHeight - laneGap)
                ForEach(lanes) { camera in
                    Text(camera.name).font(.caption).lineLimit(1).frame(height: laneHeight)
                }
            }
            .frame(width: labelWidth, alignment: .leading)
            .padding(.leading, 12)

            GeometryReader { geometry in
                let start = windowStart
                let span = min(playback.timelineSpan, playback.daySpan.duration)
                Canvas { context, size in
                    draw(&context, size: size, lanes: lanes, start: start, span: span)
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            if dragStart == nil { dragStart = start }
                            let fraction = min(max(value.location.x / max(geometry.size.width, 1), 0), 1)
                            playback.seek(to: (dragStart ?? start).addingTimeInterval(Double(fraction) * span))
                        }
                        .onEnded { _ in dragStart = nil }
                )
            }
            .padding(.trailing, 12)
        }
        .frame(height: height)
        .padding(.vertical, 4)
    }

    private func draw(_ context: inout GraphicsContext, size: CGSize, lanes: [Recordings.Camera], start: Date, span: TimeInterval) {
        func x(_ date: Date) -> CGFloat { CGFloat(date.timeIntervalSince(start) / span) * size.width }
        let end = start.addingTimeInterval(span)

        // Time axis: a tick step that leaves room for the labels.
        let steps: [TimeInterval] = [60, 300, 600, 1800, 3600, 7200, 10800, 21600]
        let step = steps.first { CGFloat($0 / span) * size.width >= 56 } ?? 21600
        let calendar = Calendar.current
        var tick = calendar.startOfDay(for: start)
        while tick < start { tick = tick.addingTimeInterval(step) }
        let label = DateFormatter()
        label.dateFormat = "HH:mm"
        while tick <= end {
            let px = x(tick)
            context.fill(Path(CGRect(x: px, y: axisHeight - 4, width: 1, height: size.height - axisHeight + 4)), with: .color(.secondary.opacity(0.18)))
            context.draw(Text(label.string(from: tick)).font(.caption2).foregroundColor(.secondary), at: CGPoint(x: px + 3, y: 7), anchor: .leading)
            tick = tick.addingTimeInterval(step)
        }

        for (row, camera) in lanes.enumerated() {
            let y = axisHeight + CGFloat(row) * (laneHeight + laneGap)
            context.fill(Path(roundedRect: CGRect(x: 0, y: y, width: size.width, height: laneHeight), cornerRadius: 3), with: .color(.secondary.opacity(0.10)))
            for clip in camera.clips where clip.end > start && clip.start < end {
                let left = max(x(clip.start), 0), right = min(x(clip.end), size.width)
                context.fill(Path(CGRect(x: left, y: y, width: max(right - left, 1), height: laneHeight)), with: .color(.accentColor.opacity(0.45)))
                for motion in clip.motion where motion.end > start && motion.start < end {
                    let from = max(x(motion.start), 0), to = min(x(motion.end), size.width)
                    context.fill(Path(CGRect(x: from, y: y + laneHeight - 5, width: max(to - from, 1), height: 5)), with: .color(.orange))
                }
            }
        }

        let px = x(playback.playhead)
        if px >= 0 && px <= size.width {
            context.fill(Path(CGRect(x: px - 0.75, y: 0, width: 1.5, height: size.height)), with: .color(.red))
        }
    }
}

/// The sheet for the read-only key that downloads recordings. On a Mac that does not record
/// it also asks where the bucket is and for the passphrase.
struct PlaybackKeyView: View {
    let onDone: () -> Void
    @State private var settings = StorageSettings.load()
    @State private var secret = ""
    @State private var passphrase = ""
    @State private var running = false
    @State private var failure: String?
    private let recordsHere = StorageSettings.load().isConfigured

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Endpoint", text: $settings.endpoint, prompt: Text("s3.eu-central-1.amazonaws.com"))
                    TextField("Region", text: $settings.region)
                    TextField("Bucket", text: $settings.bucket)
                } header: {
                    Text("Bucket")
                }
                .disabled(recordsHere)
                Section {
                    TextField("Key ID", text: $settings.readKeyID)
                    SecureField("Secret", text: $secret)
                } header: {
                    Text("Playback key")
                } footer: {
                    Text("A key that may download and nothing else. With it, recordings that are no longer on this Mac are fetched from the bucket.")
                        .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if !recordsHere {
                    Section {
                        SecureField("Passphrase", text: $passphrase)
                    } footer: {
                        Text("The passphrase the bucket was set up with. Leave empty if this Mac already has it.")
                            .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                if running { ProgressView().controlSize(.small) }
                Text(failure ?? "").font(.caption).foregroundStyle(.red).lineLimit(4).textSelection(.enabled)
                Spacer()
                Button("Cancel") { onDone() }.keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(running || settings.configuration == nil || settings.readKeyID.isEmpty || secret.isEmpty)
            }
            .padding(12)
        }
        .frame(width: 520, height: recordsHere ? 400 : 500)
    }

    private func save() {
        running = true
        failure = nil
        var input = settings
        input.endpoint = input.endpoint.trimmingCharacters(in: .whitespaces)
        input.bucket = input.bucket.trimmingCharacters(in: .whitespaces)
        input.readKeyID = input.readKeyID.trimmingCharacters(in: .whitespaces)
        Task {
            do {
                try await StorageStore.connectForPlayback(settings: input, readSecret: secret, passphrase: passphrase)
                onDone()
            } catch {
                failure = error.localizedDescription
            }
            running = false
        }
    }
}
