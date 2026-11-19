import CryptoKit
import Foundation

/// Where the off-site bucket is. Stored in the app's preferences by storage setup; the
/// secrets (the upload key's secret and the passphrase) are in the keychain.
public struct StorageSettings: Equatable, Sendable {
    public var endpoint = ""
    public var region = ""
    public var bucket = ""
    /// Id of the recorder's access key, which may upload but not delete.
    public var uploadKeyID = ""
    /// Days after which the bucket deletes a recording. Chosen once in storage setup, which
    /// writes the bucket's lifecycle rule; shown read-only afterwards.
    public var retentionDays = 14
    /// Id of the read-only key the Recordings view downloads with; empty plays the local cache only.
    public var readKeyID = ""

    public init() {}

    /// Set up for recording: the recorder can upload.
    public var isConfigured: Bool { configuration != nil && !uploadKeyID.isEmpty }

    public var configuration: S3Configuration? {
        let text = endpoint.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, !bucket.isEmpty,
              let url = URL(string: text.contains("://") ? text : "https://" + text), url.host != nil else { return nil }
        return S3Configuration(endpoint: url, region: region.isEmpty ? "us-east-1" : region, bucket: bucket)
    }

    private enum Key {
        static let endpoint = "storage.endpoint"
        static let region = "storage.region"
        static let bucket = "storage.bucket"
        static let uploadKeyID = "storage.uploadKeyID"
        static let retentionDays = "storage.retentionDays"
        static let readKeyID = "storage.readKeyID"
    }

    public static func load(from defaults: UserDefaults = .standard) -> StorageSettings {
        var s = StorageSettings()
        s.endpoint = defaults.string(forKey: Key.endpoint) ?? ""
        s.region = defaults.string(forKey: Key.region) ?? ""
        s.bucket = defaults.string(forKey: Key.bucket) ?? ""
        s.uploadKeyID = defaults.string(forKey: Key.uploadKeyID) ?? ""
        s.readKeyID = defaults.string(forKey: Key.readKeyID) ?? ""
        if defaults.object(forKey: Key.retentionDays) != nil { s.retentionDays = max(1, defaults.integer(forKey: Key.retentionDays)) }
        return s
    }

    public func save(to defaults: UserDefaults = .standard) {
        defaults.set(endpoint, forKey: Key.endpoint)
        defaults.set(region, forKey: Key.region)
        defaults.set(bucket, forKey: Key.bucket)
        defaults.set(uploadKeyID, forKey: Key.uploadKeyID)
        defaults.set(readKeyID, forKey: Key.readKeyID)
        defaults.set(retentionDays, forKey: Key.retentionDays)
    }

    /// This Mac's copy of the key file: `~/Library/Application Support/ReolinkViewer/data-key.json`.
    /// The recorder's key cannot download the one in the bucket.
    public static var keyFileURL: URL {
        RecordingStore.defaultDirectory.deletingLastPathComponent().appendingPathComponent("data-key.json")
    }
}

extension StorageSetup {
    /// Changes whenever the bucket, the key or the secret does.
    var fingerprint: String {
        let text = [configuration.endpoint.absoluteString, configuration.region, configuration.bucket,
                    credentials.accessKeyID, credentials.secretAccessKey].joined(separator: "\n")
        return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
