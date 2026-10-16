import Foundation
import Security

/// A thin Keychain wrapper. Store credentials and tokens live here — never in
/// `Documents` (every Windows program in the prefix can read Documents) and
/// never in logs.
enum Keychain {
    static let service = "com.milifrr.windoz"

    private static func query(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    @discardableResult
    static func set(_ data: Data, account: String) -> Bool {
        var q = query(account: account)
        SecItemDelete(q as CFDictionary)
        q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    static func setString(_ value: String, account: String) -> Bool {
        set(Data(value.utf8), account: account)
    }

    static func get(account: String) -> Data? {
        var q = query(account: account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    static func getString(account: String) -> String? {
        get(account: account).flatMap { String(data: $0, encoding: .utf8) }
    }

    static func remove(account: String) {
        SecItemDelete(query(account: account) as CFDictionary)
    }

    static func has(account: String) -> Bool {
        get(account: account) != nil
    }
}
