import CommonCrypto
import CryptoKit
import Foundation

public enum VaultError: Error, CustomStringConvertible {
    case wrongPassphrase
    case notSealed
    case damaged
    case unsupportedKeyFile(String)

    public var description: String {
        switch self {
        case .wrongPassphrase: return "the passphrase does not open the key file"
        case .notSealed: return "this is not a file sealed by Reolink Viewer"
        case .damaged: return "the file is damaged, was sealed with another key, or carries another name"
        case .unsupportedKeyFile(let why): return "the key file cannot be read: \(why)"
        }
    }
}

/// Seals recordings before they leave the Mac, with AES-256-GCM.
///
/// A random data key encrypts the files. The *key file* holds that key wrapped with a key
/// derived from the passphrase (PBKDF2-HMAC-SHA256), so the passphrase can change without
/// touching the recordings, and a second Mac needs only the key file and the passphrase.
///
/// A sealed file is `RVE1`, a 12-byte nonce, the ciphertext and a 16-byte tag. Its name is
/// authenticated with it, so the storage provider cannot pass one recording off as another.
public struct Vault: Sendable {
    static let magic = Data("RVE1".utf8)
    static let keyFileContext = Data("ReolinkViewer data key v1".utf8)
    public static let defaultIterations = 600_000

    private let key: SymmetricKey

    private init(key: SymmetricKey) {
        self.key = key
    }

    /// A vault with a fresh random data key.
    public static func generate() -> Vault {
        Vault(key: SymmetricKey(size: .bits256))
    }

    // MARK: Files

    /// - Parameter name: the object key the file is stored under; needed again to open it.
    public func seal(_ plaintext: Data, name: String) throws -> Data {
        let box = try AES.GCM.seal(plaintext, using: key, authenticating: Data(name.utf8))
        guard let combined = box.combined else { throw VaultError.damaged }
        return Self.magic + combined
    }

    public func open(_ sealed: Data, name: String) throws -> Data {
        guard sealed.count > Self.magic.count + 28, sealed.prefix(Self.magic.count) == Self.magic else { throw VaultError.notSealed }
        do {
            let box = try AES.GCM.SealedBox(combined: sealed.dropFirst(Self.magic.count))
            return try AES.GCM.open(box, using: key, authenticating: Data(name.utf8))
        } catch {
            throw VaultError.damaged
        }
    }

    // MARK: Key file

    private struct KeyFile: Codable {
        var version: Int
        var kdf: String
        var iterations: Int
        var salt: Data
        var wrappedKey: Data
    }

    /// The data key wrapped with `passphrase`, as JSON.
    public func keyFile(passphrase: String, iterations: Int = Vault.defaultIterations) throws -> Data {
        var salt = Data(count: 16)
        salt.withUnsafeMutableBytes { _ = SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        let wrapping = try Self.derive(passphrase: passphrase, salt: salt, iterations: iterations)
        let box = try AES.GCM.seal(key.withUnsafeBytes { Data($0) }, using: wrapping, authenticating: Self.keyFileContext)
        guard let combined = box.combined else { throw VaultError.damaged }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(KeyFile(version: 1, kdf: "pbkdf2-hmac-sha256", iterations: iterations, salt: salt, wrappedKey: combined))
    }

    /// Opens a key file. Throws `VaultError.wrongPassphrase` when the passphrase does not fit.
    public init(keyFile data: Data, passphrase: String) throws {
        let file: KeyFile
        do {
            file = try JSONDecoder().decode(KeyFile.self, from: data)
        } catch {
            throw VaultError.unsupportedKeyFile("not a key file")
        }
        guard file.version == 1, file.kdf == "pbkdf2-hmac-sha256", file.iterations > 0 else {
            throw VaultError.unsupportedKeyFile("version \(file.version), \(file.kdf)")
        }
        let wrapping = try Self.derive(passphrase: passphrase, salt: file.salt, iterations: file.iterations)
        do {
            let box = try AES.GCM.SealedBox(combined: file.wrappedKey)
            key = SymmetricKey(data: try AES.GCM.open(box, using: wrapping, authenticating: Self.keyFileContext))
        } catch {
            throw VaultError.wrongPassphrase
        }
    }

    private static func derive(passphrase: String, salt: Data, iterations: Int) throws -> SymmetricKey {
        var derived = [UInt8](repeating: 0, count: 32)
        let password = Array(passphrase.utf8)
        let status = salt.withUnsafeBytes { saltBytes in
            password.withUnsafeBufferPointer { passwordBytes in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                                     UnsafeRawPointer(passwordBytes.baseAddress)?.assumingMemoryBound(to: CChar.self), password.count,
                                     saltBytes.bindMemory(to: UInt8.self).baseAddress, salt.count,
                                     CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(iterations), &derived, derived.count)
            }
        }
        guard status == kCCSuccess else { throw VaultError.unsupportedKeyFile("key derivation failed (\(status))") }
        return SymmetricKey(data: derived)
    }

    // MARK: Passphrase

    /// A random passphrase of six groups of five characters, about 148 bits, without the
    /// characters that are easily mistaken for each other.
    public static func generatePassphrase() -> String {
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        var generator = SystemRandomNumberGenerator()
        return (0..<6).map { _ in String((0..<5).map { _ in alphabet.randomElement(using: &generator)! }) }.joined(separator: "-")
    }
}
