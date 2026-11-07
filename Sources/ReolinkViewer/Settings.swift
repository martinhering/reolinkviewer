import Foundation
import Security

struct CameraSettings: Equatable, Identifiable, Codable {
    var id = UUID()
    /// Shown in the window title, the camera menu and the grid; the address stands in while empty.
    var name = ""
    var host = ""
    var port: UInt16 = 9000
    var username = "admin"
    var password = ""
    var ptzSpeed: Float = 32

    /// An empty password is allowed: a camera that has not been set up yet accepts `admin` without one.
    var isComplete: Bool { !host.isEmpty && !username.isEmpty }
    var displayName: String { name.isEmpty ? (host.isEmpty ? "New camera" : host) : name }

    // The password is not part of the stored document; it lives in the keychain.
    private enum CodingKeys: String, CodingKey { case id, name, host, port, username, ptzSpeed }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        host = try c.decodeIfPresent(String.self, forKey: .host) ?? ""
        port = try c.decodeIfPresent(UInt16.self, forKey: .port) ?? 9000
        username = try c.decodeIfPresent(String.self, forKey: .username) ?? "admin"
        ptzSpeed = try c.decodeIfPresent(Float.self, forKey: .ptzSpeed) ?? 32
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(host, forKey: .host)
        try c.encode(port, forKey: .port)
        try c.encode(username, forKey: .username)
        try c.encode(ptzSpeed, forKey: .ptzSpeed)
    }
}

/// The camera list (everything but the passwords) is a JSON array in UserDefaults; each
/// password is a keychain item keyed by the camera's id. `REOLINK_PASSWORD` in the environment
/// overrides every keychain password (handy when running from Terminal).
enum SettingsStore {
    private static let defaults = UserDefaults.standard
    private static let service = "com.martinhering.ReolinkViewer"
    private static let camerasKey = "cameras"

    static func load() -> [CameraSettings] {
        var cameras = storedCameras() ?? migrateLegacySettings()
        let env = ProcessInfo.processInfo.environment["REOLINK_PASSWORD"]
        for i in cameras.indices {
            if let env, !env.isEmpty {
                cameras[i].password = env
            } else {
                cameras[i].password = Keychain.read(service: service, account: account(cameras[i])) ?? ""
            }
        }
        return cameras
    }

    static func save(_ cameras: [CameraSettings]) {
        for old in storedCameras() ?? [] where !cameras.contains(where: { $0.id == old.id }) {
            Keychain.delete(service: service, account: account(old))
        }
        if let data = try? JSONEncoder().encode(cameras) {
            defaults.set(data, forKey: camerasKey)
        }
        for camera in cameras {
            Keychain.write(camera.password, service: service, account: account(camera))
        }
    }

    private static func account(_ camera: CameraSettings) -> String {
        "camera/" + camera.id.uuidString
    }

    private static func storedCameras() -> [CameraSettings]? {
        guard let data = defaults.data(forKey: camerasKey) else { return nil }
        return try? JSONDecoder().decode([CameraSettings].self, from: data)
    }

    /// Versions before the camera list kept one camera in the keys host/port/username/ptzSpeed
    /// and its password under "host/username". Carry it over once, then drop the old keys.
    private static func migrateLegacySettings() -> [CameraSettings] {
        guard let host = defaults.string(forKey: "host"), !host.isEmpty else { return [] }
        var camera = CameraSettings()
        camera.host = host
        let port = defaults.integer(forKey: "port")
        if port > 0 && port <= 65535 { camera.port = UInt16(port) }
        if let user = defaults.string(forKey: "username"), !user.isEmpty { camera.username = user }
        let speed = defaults.float(forKey: "ptzSpeed")
        if speed > 0 { camera.ptzSpeed = speed }
        let legacyAccount = camera.host + "/" + camera.username
        camera.password = Keychain.read(service: service, account: legacyAccount) ?? ""
        save([camera])
        Keychain.delete(service: service, account: legacyAccount)
        for key in ["host", "port", "username", "ptzSpeed"] { defaults.removeObject(forKey: key) }
        return [camera]
    }
}

enum Keychain {
    static func read(service: String, account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ value: String, service: String, account: String) {
        delete(service: service, account: account)
        guard !value.isEmpty else { return }
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(value.utf8),
            kSecAttrLabel as String: "Reolink camera (\(account))",
        ]
        let status = SecItemAdd(add as CFDictionary, nil)
        if status != errSecSuccess { NSLog("keychain write failed: \(status)") }
    }

    static func delete(service: String, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
