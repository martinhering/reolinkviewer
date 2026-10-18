import Foundation
import Security

struct CameraSettings: Equatable {
    var host = "192.168.178.140"
    var port: UInt16 = 9000
    var username = "admin"
    var password = ""
    var ptzSpeed: Float = 32

    var isComplete: Bool { !host.isEmpty && !username.isEmpty && !password.isEmpty }
}

/// Host, port, username and speed live in UserDefaults; the password in the login keychain.
/// `REOLINK_PASSWORD` in the environment overrides the keychain (handy when running from Terminal).
enum SettingsStore {
    private static let defaults = UserDefaults.standard
    private static let service = "com.martinhering.ReolinkViewer"

    static func load() -> CameraSettings {
        var s = CameraSettings()
        if let host = defaults.string(forKey: "host"), !host.isEmpty { s.host = host }
        let port = defaults.integer(forKey: "port")
        if port > 0 && port <= 65535 { s.port = UInt16(port) }
        if let user = defaults.string(forKey: "username"), !user.isEmpty { s.username = user }
        let speed = defaults.float(forKey: "ptzSpeed")
        if speed > 0 { s.ptzSpeed = speed }
        if let env = ProcessInfo.processInfo.environment["REOLINK_PASSWORD"], !env.isEmpty {
            s.password = env
        } else {
            s.password = Keychain.read(service: service, account: s.host + "/" + s.username) ?? ""
        }
        return s
    }

    static func save(_ s: CameraSettings) {
        defaults.set(s.host, forKey: "host")
        defaults.set(Int(s.port), forKey: "port")
        defaults.set(s.username, forKey: "username")
        defaults.set(s.ptzSpeed, forKey: "ptzSpeed")
        Keychain.write(s.password, service: service, account: s.host + "/" + s.username)
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
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        guard !value.isEmpty else { return }
        var add = query
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrLabel as String] = "Reolink camera (\(account))"
        let status = SecItemAdd(add as CFDictionary, nil)
        if status != errSecSuccess { NSLog("keychain write failed: \(status)") }
    }
}
