import Foundation
import Recording

/// The off-site storage as this Mac knows it: where the bucket is (preferences), the upload
/// key's secret and the passphrase (keychain), and a copy of the key file (Application Support).
///
/// Environment, for running the recorder from Terminal: `REOLINK_S3_SECRET`,
/// `REOLINK_PASSPHRASE` and `REOLINK_KEY_FILE` replace the keychain items and the key file.
enum StorageStore {
    private static let service = "com.martinhering.ReolinkViewer"
    private static let secretAccount = "storage/uploadSecret"
    private static let passphraseAccount = "storage/passphrase"

    private static var keyFileURL: URL {
        if let path = ProcessInfo.processInfo.environment["REOLINK_KEY_FILE"], !path.isEmpty { return URL(fileURLWithPath: path) }
        return StorageSettings.keyFileURL
    }

    /// What the recorder needs to upload, or nil while storage is not set up (or its secrets
    /// cannot be read).
    static func loadSetup() -> StorageSetup? {
        let settings = StorageSettings.load()
        let env = ProcessInfo.processInfo.environment
        guard settings.isConfigured, let configuration = settings.configuration,
              let secret = env["REOLINK_S3_SECRET"] ?? Keychain.read(service: service, account: secretAccount), !secret.isEmpty,
              let passphrase = env["REOLINK_PASSPHRASE"] ?? Keychain.read(service: service, account: passphraseAccount),
              let keyFile = try? Data(contentsOf: keyFileURL),
              let vault = try? Vault(keyFile: keyFile, passphrase: passphrase) else { return nil }
        return StorageSetup(configuration: configuration,
                            credentials: S3Credentials(accessKeyID: settings.uploadKeyID, secretAccessKey: secret), vault: vault)
    }

    // MARK: Setup

    struct SetupInput {
        var settings = StorageSettings()
        var uploadSecret = ""
        /// A key that may read, write and change the bucket's lifecycle rule. Used during
        /// setup only and not stored.
        var setupKeyID = ""
        var setupSecret = ""
        /// Empty: generate one, unless the bucket already has a key file.
        var passphrase = ""
        /// Off when the provider has no lifecycle rules or the rule is managed elsewhere.
        var writeLifecycleRule = true

        var isComplete: Bool {
            settings.isConfigured && !uploadSecret.isEmpty && !setupKeyID.isEmpty && !setupSecret.isEmpty
        }
    }

    struct SetupResult {
        /// The passphrase, when setup generated it: to be shown once.
        var generatedPassphrase: String?
        /// The bucket already had a key file, which the passphrase opened.
        var joinedExistingBucket: Bool
    }

    struct SetupError: LocalizedError {
        let errorDescription: String?
        init(_ text: String) { errorDescription = text }
    }

    private static func describe(_ error: Error) -> String {
        error is S3Error || error is VaultError ? "\(error)" : error.localizedDescription
    }

    /// Checks both keys against the bucket, writes the lifecycle rule and the key file, and
    /// stores everything on this Mac. Nothing is stored unless every step worked.
    static func runSetup(_ input: SetupInput) async throws -> SetupResult {
        guard let configuration = input.settings.configuration else { throw SetupError("The endpoint or the bucket is missing.") }
        let setupClient = S3Client(configuration: configuration,
                                   credentials: S3Credentials(accessKeyID: input.setupKeyID, secretAccessKey: input.setupSecret))
        let uploadClient = S3Client(configuration: configuration,
                                    credentials: S3Credentials(accessKeyID: input.settings.uploadKeyID, secretAccessKey: input.uploadSecret))

        // 1. The key file: open the bucket's, or make a new one.
        var existing: Data?
        do {
            existing = try await setupClient.getObject(key: StorageLayout.keyFileKey)
        } catch let error as S3Error where error.isNotFound {
            existing = nil
        } catch {
            throw SetupError("The setup key cannot read the bucket: \(describe(error))")
        }
        let vault: Vault
        var passphrase = input.passphrase
        var generated: String?
        if let existing {
            guard !passphrase.isEmpty else {
                throw SetupError("This bucket already holds recordings. Enter the passphrase it was set up with.")
            }
            do {
                vault = try Vault(keyFile: existing, passphrase: passphrase)
            } catch {
                throw SetupError("This bucket already holds recordings, and \(describe(error)).")
            }
        } else {
            vault = Vault.generate()
            if passphrase.isEmpty {
                passphrase = Vault.generatePassphrase()
                generated = passphrase
            }
        }
        let keyFile = try existing ?? vault.keyFile(passphrase: passphrase)

        // 2. The upload key must be able to write under the recordings prefix.
        do {
            try await uploadClient.putObject(key: StorageLayout.recordingsPrefix + "setup-check", data: Data("ok".utf8))
        } catch {
            throw SetupError("The upload key cannot write to the bucket: \(describe(error))")
        }

        // 3. Retention: the bucket deletes recordings by itself.
        if input.writeLifecycleRule {
            do {
                try await setupClient.putLifecycle(expireAfterDays: input.settings.retentionDays, prefix: StorageLayout.recordingsPrefix)
            } catch {
                throw SetupError("The bucket's lifecycle rule could not be written: \(describe(error)). "
                                 + "If the provider has no lifecycle rules, or you set the rule there yourself, switch the option off.")
            }
        }

        // 4. A new key file goes into the bucket, outside the prefix that expires.
        if existing == nil {
            do {
                try await setupClient.putObject(key: StorageLayout.keyFileKey, data: keyFile, contentType: "application/json")
            } catch {
                throw SetupError("The key file could not be stored in the bucket: \(describe(error))")
            }
        }

        // 5. Remember it all on this Mac.
        do {
            try FileManager.default.createDirectory(at: StorageSettings.keyFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try keyFile.write(to: StorageSettings.keyFileURL, options: .atomic)
        } catch {
            throw SetupError("The key file could not be saved on this Mac: \(error.localizedDescription)")
        }
        Keychain.write(input.uploadSecret, service: service, account: secretAccount)
        Keychain.write(passphrase, service: service, account: passphraseAccount)
        input.settings.save()
        SettingsStore.notifyRecorder()
        return SetupResult(generatedPassphrase: generated, joinedExistingBucket: existing != nil)
    }
}
