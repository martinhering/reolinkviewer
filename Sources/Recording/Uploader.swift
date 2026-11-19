import Foundation

/// Everything the recorder needs to send recordings off-site.
public struct StorageSetup: Sendable {
    public var configuration: S3Configuration
    /// The recorder's key: may upload, may not delete.
    public var credentials: S3Credentials
    public var vault: Vault

    public init(configuration: S3Configuration, credentials: S3Credentials, vault: Vault) {
        self.configuration = configuration
        self.credentials = credentials
        self.vault = vault
    }
}

/// Names in the bucket. Everything that expires lives under `recordings/`, which is what the
/// lifecycle rule covers; the key file lives outside it and stays.
public enum StorageLayout {
    public static let recordingsPrefix = "recordings/"
    public static let keyFileKey = "keys/data-key.json"

    /// `recordings/<camera id>/2026-11-19/135400Z_60s.mp4.enc`
    public static func fileKey(camera: UUID, day: String, name: String) -> String {
        "\(recordingsPrefix)\(camera.uuidString)/\(day)/\(name)"
    }

    /// `recordings/index/2026-11-19.json.enc`
    public static func indexKey(day: String) -> String {
        "\(recordingsPrefix)index/\(day).json.enc"
    }
}

/// One day's recordings of all cameras: which files exist and when there was motion. The
/// viewer draws a day's timeline from this one object.
public struct DayIndex: Codable, Equatable, Sendable {
    public struct File: Codable, Equatable, Sendable {
        /// File name inside the camera's day folder, e.g. `135400Z_60s.mp4.enc`.
        public var name: String
        public var start: Date
        public var duration: TimeInterval
        /// Size of the sealed file.
        public var bytes: Int
        /// Motion inside the file as start and end, in seconds since 1970.
        public var motion: [[Double]]
    }

    public struct Camera: Codable, Equatable, Sendable {
        public var name: String
        public var files: [File]
    }

    public var version = 1
    /// `yyyy-MM-dd` in UTC.
    public var day: String
    /// By camera id.
    public var cameras: [String: Camera] = [:]

    public init(day: String) {
        self.day = day
    }

    /// Adds a file, replacing an entry of the same name, and keeps the files in time order.
    public mutating func add(_ file: File, camera: UUID, cameraName: String) {
        var entry = cameras[camera.uuidString] ?? Camera(name: cameraName, files: [])
        entry.name = cameraName
        entry.files.removeAll { $0.name == file.name }
        entry.files.append(file)
        entry.files.sort { $0.start < $1.start }
        cameras[camera.uuidString] = entry
    }
}

/// Seals kept recordings and uploads them. The queue is a folder of small job files, so it
/// survives restarts and catches up after an outage.
///
/// On the Mac a kept `…/135400Z_60s.mp4` becomes `…/135400Z_60s.mp4.enc`; the clear file is
/// deleted. After the upload the file is entered in the day index, which is uploaded too.
public actor Uploader {
    private struct Job: Codable {
        var objectKey: String
        /// Path of the sealed file below the root folder.
        var path: String
        var camera: UUID?
        var cameraName: String?
        var day: String
        var file: DayIndex.File?
    }

    private let root: URL
    private let vault: Vault
    private let client: S3Client
    private let log: @Sendable (String) -> Void
    private var failing = false

    private var queue: URL { root.appendingPathComponent("queue", isDirectory: true) }
    private var indexFolder: URL { root.appendingPathComponent("index", isDirectory: true) }

    public init(root: URL, setup: StorageSetup, session: URLSession = .shared, log: @escaping @Sendable (String) -> Void) {
        self.root = root
        self.vault = setup.vault
        self.client = S3Client(configuration: setup.configuration, credentials: setup.credentials, session: session)
        self.log = log
    }

    /// Number of uploads waiting.
    public var pending: Int {
        ((try? FileManager.default.contentsOfDirectory(atPath: queue.path)) ?? []).filter { $0.hasSuffix(".json") }.count
    }

    // MARK: Queueing

    /// Seals a kept recording and queues its upload. `url` is `<root>/<camera id>/<day>/<name>.mp4`.
    public func enqueue(file url: URL, camera: UUID, cameraName: String, start: Date, duration: TimeInterval, motion: [DateInterval]) {
        let day = url.deletingLastPathComponent().lastPathComponent
        let name = url.lastPathComponent + ".enc"
        let objectKey = StorageLayout.fileKey(camera: camera, day: day, name: name)
        let sealedURL = url.appendingPathExtension("enc")
        do {
            let sealed = try vault.seal(try Data(contentsOf: url), name: objectKey)
            try sealed.write(to: sealedURL, options: .atomic)
            let entry = DayIndex.File(name: name, start: start, duration: duration, bytes: sealed.count,
                                      motion: motion.map { [$0.start.timeIntervalSince1970, $0.end.timeIntervalSince1970] })
            let job = Job(objectKey: objectKey, path: "\(camera.uuidString)/\(day)/\(name)", camera: camera, cameraName: cameraName,
                          day: day, file: entry)
            try write(job, named: "\(Self.stamp(start))_\(camera.uuidString)_\(name).json")
            try FileManager.default.removeItem(at: url)
        } catch {
            log("could not seal \(url.lastPathComponent): \(error)")
        }
    }

    /// Queues the clear recordings found in the dated folders: kept before storage was set
    /// up, or left by a recorder that stopped between keeping and sealing.
    public func enqueueLeftovers(cameraNames: [UUID: String]) {
        let fm = FileManager.default
        for folder in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
            guard let camera = UUID(uuidString: folder.lastPathComponent) else { continue }
            for day in (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] where day.lastPathComponent != "pending" {
                for file in (try? fm.contentsOfDirectory(at: day, includingPropertiesForKeys: nil)) ?? [] where file.pathExtension == "mp4" {
                    guard let (start, duration) = Self.parse(day: day.lastPathComponent, name: file.lastPathComponent) else { continue }
                    enqueue(file: file, camera: camera, cameraName: cameraNames[camera] ?? camera.uuidString,
                            start: start, duration: duration, motion: [])
                }
            }
        }
    }

    /// Start time and nominal length from `2026-11-19` and `135400Z_60s.mp4`.
    static func parse(day: String, name: String) -> (Date, TimeInterval)? {
        let parts = name.split(separator: "_")
        guard parts.count == 2, let seconds = Double(parts[1].prefix { $0.isNumber }) else { return nil }
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd HHmmss'Z'"
        guard let start = f.date(from: "\(day) \(parts[0])") else { return nil }
        return (start, seconds)
    }

    private static func stamp(_ date: Date) -> String {
        String(format: "%012.0f", date.timeIntervalSince1970)
    }

    private func write(_ job: Job, named name: String) throws {
        try FileManager.default.createDirectory(at: queue, withIntermediateDirectories: true)
        try JSONEncoder().encode(job).write(to: queue.appendingPathComponent(name), options: .atomic)
    }

    // MARK: Uploading

    /// Works through the queue until the task is cancelled.
    public func run() async {
        var backoff = 5.0
        while !Task.isCancelled {
            let worked = await uploadNext()
            switch worked {
            case .some(true):
                backoff = 5
            case .some(false):
                try? await Task.sleep(for: .seconds(backoff))
                backoff = min(backoff * 2, 60)
            case .none:
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    /// Uploads the oldest job. Returns nil when the queue is empty, false when the upload failed.
    func uploadNext() async -> Bool? {
        let fm = FileManager.default
        let names = ((try? fm.contentsOfDirectory(atPath: queue.path)) ?? []).filter { $0.hasSuffix(".json") }.sorted()
        // Index jobs sort last ("index…" after the digits of a time stamp), so a day's index
        // goes up after the files it lists.
        guard let name = names.first else { return nil }
        let jobURL = queue.appendingPathComponent(name)
        guard let job = try? JSONDecoder().decode(Job.self, from: Data(contentsOf: jobURL)) else {
            try? fm.removeItem(at: jobURL)
            return true
        }
        let fileURL = root.appendingPathComponent(job.path)
        guard let data = try? Data(contentsOf: fileURL) else {
            // The file is gone (cleared from the cache before it could be uploaded).
            log("gave up on \(job.objectKey): the file is gone")
            try? fm.removeItem(at: jobURL)
            return true
        }
        do {
            try await client.putObject(key: job.objectKey, data: data)
        } catch {
            if !failing {
                failing = true
                log("upload failed, will retry: \(error is S3Error ? "\(error)" : error.localizedDescription)")
            }
            return false
        }
        if failing {
            failing = false
            log("uploads work again, \(names.count - 1) waiting")
        }
        try? fm.removeItem(at: jobURL)
        if let file = job.file, let camera = job.camera {
            log(String(format: "uploaded %@  %.1f MB", job.objectKey, Double(data.count) / 1e6))
            addToIndex(file, camera: camera, cameraName: job.cameraName ?? camera.uuidString, day: job.day)
        }
        return true
    }

    /// Enters an uploaded file in its day's index and queues the index for upload.
    private func addToIndex(_ file: DayIndex.File, camera: UUID, cameraName: String, day: String) {
        let key = StorageLayout.indexKey(day: day)
        let url = indexFolder.appendingPathComponent("\(day).json.enc")
        var index = DayIndex(day: day)
        if let sealed = try? Data(contentsOf: url), let data = try? vault.open(sealed, name: key),
           let stored = try? JSONDecoder().decode(DayIndex.self, from: data) {
            index = stored
        }
        index.add(file, camera: camera, cameraName: cameraName)
        do {
            try FileManager.default.createDirectory(at: indexFolder, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try vault.seal(try encoder.encode(index), name: key).write(to: url, options: .atomic)
            // One job per day: a later change replaces the waiting one.
            try write(Job(objectKey: key, path: "index/\(day).json.enc", day: day), named: "index_\(day).json")
        } catch {
            log("could not update the index of \(day): \(error)")
        }
    }
}
