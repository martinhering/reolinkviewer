import Foundation

/// One recorded file of one camera.
public struct Clip: Equatable, Hashable, Sendable, Identifiable {
    public let camera: UUID
    /// UTC day folder, `yyyy-MM-dd`.
    public let day: String
    /// File name in the bucket, e.g. `135400Z_60s.mp4.enc`.
    public let name: String
    public let start: Date
    public let duration: TimeInterval
    /// Motion inside the clip.
    public let motion: [DateInterval]

    public var id: String { "\(camera.uuidString)/\(day)/\(name)" }
    public var end: Date { start.addingTimeInterval(duration) }
    public var objectKey: String { StorageLayout.fileKey(camera: camera, day: day, name: name) }

    public func contains(_ date: Date) -> Bool { date >= start && date < end }

    public init(camera: UUID, day: String, file: DayIndex.File) {
        self.camera = camera
        self.day = day
        self.name = file.name
        self.start = file.start
        self.duration = file.duration
        self.motion = file.motion.compactMap { pair in
            guard pair.count == 2, pair[1] >= pair[0] else { return nil }
            return DateInterval(start: Date(timeIntervalSince1970: pair[0]), end: Date(timeIntervalSince1970: pair[1]))
        }
    }
}

/// The recordings of a span of time, by camera, for the timeline and the players.
public struct Recordings: Equatable, Sendable {
    public struct Camera: Equatable, Sendable, Identifiable {
        public let id: UUID
        public var name: String
        /// In time order.
        public var clips: [Clip]
    }

    public var cameras: [Camera] = []

    public init() {}

    public var isEmpty: Bool { cameras.allSatisfy { $0.clips.isEmpty } }

    public func clips(of camera: UUID) -> [Clip] {
        cameras.first { $0.id == camera }?.clips ?? []
    }

    /// The clip of `camera` that covers `date`.
    public func clip(of camera: UUID, at date: Date) -> Clip? {
        clips(of: camera).first { $0.contains(date) }
    }

    /// The clip that follows `clip` on the same camera.
    public func clip(after clip: Clip) -> Clip? {
        clips(of: clip.camera).first { $0.start > clip.start }
    }

    /// The earliest clip start after `date` among `cameras` (all when nil).
    public func nextStart(after date: Date, cameras ids: Set<UUID>? = nil) -> Date? {
        cameras.filter { ids?.contains($0.id) ?? true }
            .compactMap { camera in camera.clips.first { $0.start > date }?.start }.min()
    }

    public var earliestStart: Date? { cameras.compactMap { $0.clips.first?.start }.min() }

    /// Merges day indexes, keeping the clips that overlap `span`. Cameras come in `order`
    /// first (the order of Settings), then the unknown ones by name.
    public static func merging(_ indexes: [DayIndex], within span: DateInterval, order: [UUID]) -> Recordings {
        var byCamera: [UUID: Camera] = [:]
        for index in indexes {
            for (key, entry) in index.cameras {
                guard let id = UUID(uuidString: key) else { continue }
                var camera = byCamera[id] ?? Camera(id: id, name: entry.name, clips: [])
                camera.name = entry.name
                camera.clips += entry.files.map { Clip(camera: id, day: index.day, file: $0) }
                    .filter { $0.end > span.start && $0.start < span.end }
                byCamera[id] = camera
            }
        }
        var result = Recordings()
        for id in order {
            if var camera = byCamera.removeValue(forKey: id), !camera.clips.isEmpty {
                camera.clips.sort { $0.start < $1.start }
                result.cameras.append(camera)
            }
        }
        for var camera in byCamera.values.sorted(by: { $0.name < $1.name }) where !camera.clips.isEmpty {
            camera.clips.sort { $0.start < $1.start }
            result.cameras.append(camera)
        }
        return result
    }

    /// The UTC day folders that hold the recordings of `span`.
    public static func days(covering span: DateInterval) -> [String] {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        var days: [String] = []
        var date = span.start
        while date < span.end {
            let day = f.string(from: date)
            if days.last != day { days.append(day) }
            date = date.addingTimeInterval(3600)
        }
        let last = f.string(from: span.end.addingTimeInterval(-1))
        if days.last != last { days.append(last) }
        return days
    }
}

/// Reads recordings for playback: from this Mac's cache where it has them, else from the
/// bucket with a read-only key. Everything comes back decrypted, in memory.
public struct RecordingLibrary: Sendable {
    private let root: URL
    private let vault: Vault
    private let reader: S3Client?

    /// - Parameter reader: a client with a key that may download; nil plays the local cache only.
    public init(root: URL = RecordingStore.defaultDirectory, vault: Vault, reader: S3Client?) {
        self.root = root
        self.vault = vault
        self.reader = reader
    }

    public var canDownload: Bool { reader != nil }

    /// A day's index, or nil when nothing was recorded that day. The bucket's copy wins when
    /// it can be had: on a Mac that does not record, the local one would be stale.
    public func index(day: String) async throws -> DayIndex? {
        let key = StorageLayout.indexKey(day: day)
        let local = root.appendingPathComponent("index/\(day).json.enc")
        var sealed: Data?
        var failure: Error?
        if let reader {
            do {
                sealed = try await reader.getObject(key: key)
            } catch let error as S3Error where error.isNotFound {
                sealed = nil
            } catch {
                failure = error
            }
        }
        // The recorder's own index is at least as new as the bucket's.
        if let own = try? Data(contentsOf: local), sealed == nil || isRecorderIndex(local) { sealed = own }
        guard let sealed else {
            if let failure { throw failure }
            return nil
        }
        return try JSONDecoder().decode(DayIndex.self, from: vault.open(sealed, name: key))
    }

    /// Whether this Mac's recorder wrote the local index: it keeps a queue folder next to it.
    private func isRecorderIndex(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent("queue").path)
    }

    /// A clip's MP4, decrypted. A downloaded clip is added to the local cache, still sealed.
    public func data(for clip: Clip) async throws -> Data {
        let local = RecordingStore.directory(for: clip.camera, in: root).appendingPathComponent("\(clip.day)/\(clip.name)")
        if let sealed = try? Data(contentsOf: local), let clear = try? vault.open(sealed, name: clip.objectKey) {
            return clear
        }
        guard let reader else { throw LibraryError.notOnThisMac }
        let sealed = try await reader.getObject(key: clip.objectKey)
        let clear = try vault.open(sealed, name: clip.objectKey)
        try? FileManager.default.createDirectory(at: local.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? sealed.write(to: local, options: .atomic)
        return clear
    }
}

public enum LibraryError: Error, CustomStringConvertible {
    case notOnThisMac

    public var description: String {
        "this recording is no longer on this Mac, and no playback key is set up to download it"
    }
}
