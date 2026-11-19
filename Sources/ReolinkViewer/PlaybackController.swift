import AVFoundation
import Foundation
import Recording
import SwiftUI

/// One camera's player in the Recordings view. A queue player, so that the next minute can be
/// lined up behind the running one and playback crosses the boundary without a break.
@MainActor
final class ClipPlayer: ObservableObject, Identifiable {
    nonisolated let id: UUID
    let player = AVQueuePlayer()
    private var entries: [(clip: Clip, source: MemoryClipItem)] = []
    var needsSync = true
    var seeking = false
    @Published var isLoading = false
    @Published var failure: String?

    init(id: UUID) {
        self.id = id
        // The controller starts all players against one clock; a player that waits by
        // itself would fall out of step.
        player.automaticallyWaitsToMinimizeStalling = false
        player.actionAtItemEnd = .advance
    }

    /// The clip the player is on.
    var current: Clip? {
        guard let item = player.currentItem else { return nil }
        return entries.first { $0.source.item === item }?.clip
    }

    var currentItem: AVPlayerItem? { player.currentItem }

    func isQueued(_ clip: Clip) -> Bool {
        entries.contains { $0.clip == clip && player.items().contains($0.source.item) }
    }

    /// Drops everything and starts on `clip`.
    func start(_ clip: Clip, data: Data) {
        player.removeAllItems()
        let source = MemoryClipItem(data: data)
        entries = [(clip, source)]
        player.insert(source.item, after: nil)
        needsSync = true
        seeking = false
    }

    /// Lines `clip` up behind what is playing.
    func enqueue(_ clip: Clip, data: Data) {
        let playing = player.items()
        entries.removeAll { entry in !playing.contains(entry.source.item) }
        let source = MemoryClipItem(data: data)
        entries.append((clip, source))
        player.insert(source.item, after: nil)
    }

    func clear() {
        guard !entries.isEmpty || player.currentItem != nil else { return }
        player.removeAllItems()
        entries = []
        needsSync = true
    }
}

/// Drives the Recordings view: one playhead in wall-clock time, and a player per camera that
/// is kept on the clip under the playhead and in step with it.
@MainActor
final class PlaybackController: ObservableObject {
    enum Layout: String {
        case single, grid
    }

    static let rates: [Float] = [1, 2, 4, 8]

    // What is shown.
    @Published private(set) var day: Date
    @Published private(set) var recordings = Recordings()
    @Published var layout: Layout = .single
    @Published var selectedCamera: UUID?
    /// The camera heard in the grid; nil for silence.
    @Published var audibleCamera: UUID?
    @Published var muted = false
    /// Seconds of the day that the timeline shows.
    @Published var timelineSpan: TimeInterval = 86400

    // Transport.
    @Published private(set) var playhead: Date
    @Published private(set) var isPlaying = false
    @Published var rate: Float = 1 {
        didSet { if oldValue != rate { anchor() } }
    }

    // State of the library.
    @Published private(set) var isLoadingDay = false
    @Published private(set) var message: String?
    @Published private(set) var players: [UUID: ClipPlayer] = [:]
    /// The cameras with a clip under the playhead, in order: the grid's tiles.
    @Published private(set) var visibleCameras: [UUID] = []

    private var library: RecordingLibrary?
    private var cameraOrder: [UUID] = []
    private var timer: Timer?
    private var anchorWall = Date()
    private var anchorHost = CACurrentMediaTime()
    private var cache: [String: Data] = [:]
    private var cacheOrder: [String] = []
    private var loading: Set<String> = []
    private var failed: [String: String] = [:]
    private var lastReload = Date.distantPast
    private var loadGeneration = 0

    init() {
        let start = Calendar.current.startOfDay(for: Date())
        day = start
        playhead = start
    }

    var daySpan: DateInterval {
        DateInterval(start: day, end: Calendar.current.date(byAdding: .day, value: 1, to: day) ?? day.addingTimeInterval(86400))
    }

    /// The cameras the current layout plays.
    var shownCameras: [UUID] {
        switch layout {
        case .grid: return recordings.cameras.map(\.id)
        case .single: return (selectedCamera ?? recordings.cameras.first?.id).map { [$0] } ?? []
        }
    }

    var canDownload: Bool { library?.canDownload ?? false }

    // MARK: Lifecycle

    /// Opens the library and shows today. `order` is the camera order of Settings.
    func start(order: [UUID]) {
        cameraOrder = order
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        openLibrary()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        pause()
        for player in players.values { player.clear() }
    }

    /// Reads the key file and the keys again, for example after storage was set up.
    func openLibrary() {
        isLoadingDay = true
        Task {
            // Deriving the key from the passphrase takes a moment: off the main thread.
            let library = await Task.detached { StorageStore.loadLibrary() }.value
            self.library = library
            if library == nil {
                isLoadingDay = false
                message = "Recordings can be played once off-site storage is set up in Settings › Recording."
            } else {
                show(day: day, keepPlayhead: false)
            }
        }
    }

    // MARK: Days

    func show(day newDay: Date, keepPlayhead: Bool = false) {
        guard let library else { return }
        let start = Calendar.current.startOfDay(for: newDay)
        if start != day {
            pause()
            for player in players.values { player.clear() }
        }
        day = start
        let span = daySpan
        isLoadingDay = true
        loadGeneration += 1
        let generation = loadGeneration
        let order = cameraOrder
        Task {
            var indexes: [DayIndex] = []
            var failure: String?
            for name in Recordings.days(covering: span) {
                do {
                    if let index = try await library.index(day: name) { indexes.append(index) }
                } catch {
                    failure = error is S3Error || error is VaultError ? "\(error)" : error.localizedDescription
                }
            }
            guard generation == loadGeneration else { return }
            let loaded = Recordings.merging(indexes, within: span, order: order)
            recordings = loaded
            lastReload = Date()
            isLoadingDay = false
            for camera in loaded.cameras where players[camera.id] == nil { players[camera.id] = ClipPlayer(id: camera.id) }
            if selectedCamera == nil || !loaded.cameras.contains(where: { $0.id == selectedCamera }) {
                selectedCamera = loaded.cameras.first?.id
            }
            if let failure {
                message = "The recordings of this day could not be read: \(failure)"
            } else if loaded.isEmpty {
                message = "No recordings on this day."
            } else {
                message = nil
            }
            if !keepPlayhead {
                seek(to: loaded.earliestStart ?? span.start)
            }
        }
    }

    // MARK: Transport

    func togglePlay() {
        isPlaying ? pause() : play()
    }

    func play() {
        guard !recordings.isEmpty else { return }
        isPlaying = true
        anchor()
    }

    func pause() {
        guard isPlaying else { return }
        isPlaying = false
        for player in players.values { player.player.pause() }
    }

    func seek(to date: Date) {
        let span = daySpan
        playhead = min(max(date, span.start), span.end.addingTimeInterval(-0.001))
        anchor()
        for player in players.values { player.needsSync = true }
    }

    /// Moves to the start of the next or previous clip of the shown cameras.
    func skip(forward: Bool) {
        let ids = Set(shownCameras)
        if forward {
            if let next = recordings.nextStart(after: playhead, cameras: ids) { seek(to: next) }
        } else {
            let starts = recordings.cameras.filter { ids.contains($0.id) }.flatMap { $0.clips.map(\.start) }
            if let previous = starts.filter({ $0 < playhead.addingTimeInterval(-2) }).max() { seek(to: previous) }
        }
    }

    /// Opens `camera` alone at the current playhead.
    func showAlone(_ camera: UUID) {
        selectedCamera = camera
        layout = .single
    }

    /// The decrypted MP4 under the playhead of the single camera, for saving.
    func currentClipForSaving() -> (clip: Clip, data: Data)? {
        guard layout == .single, let id = shownCameras.first, let clip = recordings.clip(of: id, at: playhead),
              let data = cache[clip.id] else { return nil }
        return (clip, data)
    }

    private func anchor() {
        anchorWall = playhead
        anchorHost = CACurrentMediaTime()
        for player in players.values { player.needsSync = true }
    }

    // MARK: The clock

    private func tick() {
        let now = CACurrentMediaTime()
        let shown = shownCameras
        if isPlaying {
            playhead = anchorWall.addingTimeInterval((now - anchorHost) * Double(rate))
            if playhead >= daySpan.end {
                playhead = daySpan.end.addingTimeInterval(-0.001)
                pause()
            }
        }

        var wanted: [UUID: Clip] = [:]
        for id in shown {
            if let clip = recordings.clip(of: id, at: playhead) { wanted[id] = clip }
        }
        if isPlaying {
            if wanted.isEmpty {
                // Nothing recorded here: go on to the next moment any shown camera has something.
                if let next = recordings.nextStart(after: playhead, cameras: Set(shown)) {
                    seek(to: next)
                    for id in shown {
                        if let clip = recordings.clip(of: id, at: playhead) { wanted[id] = clip }
                    }
                } else {
                    pause()
                }
            } else if wanted.values.allSatisfy({ cache[$0.id] == nil && failed[$0.id] == nil }) {
                // Every clip under the playhead is still on its way: wait for the first.
                anchorWall = playhead
                anchorHost = now
            }
        }

        for (id, player) in players {
            sync(player, with: wanted[id], now: now)
        }
        let visible = shown.filter { wanted[$0] != nil }
        if visible != visibleCameras { visibleCameras = visible }

        // Today's index grows while the recorder runs.
        if Calendar.current.isDateInToday(day), Date().timeIntervalSince(lastReload) > 60, !isLoadingDay {
            lastReload = Date()
            show(day: day, keepPlayhead: true)
        }
    }

    /// Puts `player` on `clip` at the playhead's position, or empties it.
    private func sync(_ player: ClipPlayer, with clip: Clip?, now: CFTimeInterval) {
        guard let clip else {
            player.clear()
            if player.isLoading { player.isLoading = false }
            if player.failure != nil { player.failure = nil }
            return
        }
        let slack = 0.5 * Double(rate)
        let current = player.current
        if current != clip {
            // Crossing a boundary, the player and the playhead may be on neighbouring clips for a moment.
            let neighbours = current.map { abs($0.end.timeIntervalSince(clip.start)) < 1.5 || abs(clip.end.timeIntervalSince($0.start)) < 1.5 } ?? false
            let nearBoundary = abs(playhead.timeIntervalSince(clip.start)) < slack || abs(clip.end.timeIntervalSince(playhead)) < slack
            if isPlaying, neighbours, nearBoundary, !player.needsSync { return }
            if let data = cache[clip.id] {
                player.start(clip, data: data)
                if player.isLoading { player.isLoading = false }
                if player.failure != nil { player.failure = nil }
            } else {
                player.clear()
                if let why = failed[clip.id] {
                    if player.failure != why { player.failure = why }
                    if player.isLoading { player.isLoading = false }
                } else {
                    load(clip)
                    if !player.isLoading { player.isLoading = true }
                    if player.failure != nil { player.failure = nil }
                }
                return
            }
        }
        player.player.isMuted = rate > 2 || (layout == .grid ? audibleCamera != player.id : muted)

        guard let item = player.currentItem, item.status == .readyToPlay else { return }
        let expected = playhead.timeIntervalSince(clip.start)
        let actual = item.currentTime().seconds
        if isPlaying {
            if player.needsSync || abs(actual - expected) > 0.4 || player.player.rate != rate {
                // Start (or correct) against the shared clock, a moment ahead so that every
                // player has the same instant to aim for.
                let lead = 0.05
                let hostTime = CMClockGetTime(CMClockGetHostTimeClock()) + CMTime(seconds: lead, preferredTimescale: 1_000_000)
                player.player.setRate(rate, time: CMTime(seconds: expected + lead * Double(rate), preferredTimescale: 1_000_000), atHostTime: hostTime)
                player.needsSync = false
            }
        } else {
            if player.player.rate != 0 { player.player.pause() }
            if (player.needsSync || abs(actual - expected) > 0.03), !player.seeking {
                player.seeking = true
                player.needsSync = false
                item.seek(to: CMTime(seconds: expected, preferredTimescale: 1_000_000), toleranceBefore: .zero, toleranceAfter: .zero) { [weak player] _ in
                    Task { @MainActor in player?.seeking = false }
                }
            }
        }

        // Line the next minute up before this one ends.
        if let next = recordings.clip(after: clip), next.start.timeIntervalSince(clip.end) < 1.5,
           clip.end.timeIntervalSince(playhead) < 15 * Double(rate) {
            if let data = cache[next.id] {
                if !player.isQueued(next) { player.enqueue(next, data: data) }
            } else if failed[next.id] == nil {
                load(next)
            }
        }
    }

    // MARK: Clip data

    private func load(_ clip: Clip) {
        guard let library, cache[clip.id] == nil, !loading.contains(clip.id) else { return }
        loading.insert(clip.id)
        Task {
            do {
                let data = try await Task.detached { try await library.data(for: clip) }.value
                cache[clip.id] = data
                cacheOrder.append(clip.id)
                // A handful of minutes per camera is plenty; they are 5 to 25 MB each.
                while cacheOrder.count > max(8, players.count * 4) {
                    cache[cacheOrder.removeFirst()] = nil
                }
            } catch {
                failed[clip.id] = error is S3Error || error is VaultError || error is LibraryError ? "\(error)" : error.localizedDescription
            }
            loading.remove(clip.id)
        }
    }
}
