import Foundation
import Security

/// A thin Keychain wrapper. Store credentials and tokens live here — never in
/// `Documents` (every Windows program in the prefix can read Documents) and
/// never in logs.
enum Keychain {
    /// Service name is Windoz's own, not an access group. LiveContainer assigns
    /// random keychain groups to containers; specifying a group here would miss
    /// items after a re-sign or a container move.
    static var service: String { "com.milifrr.windoz" }

    private static func query(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
        ]
    }

    @discardableResult
    static func set(_ data: Data, account: String) -> Bool {
        var q = query(account: account)
        SecItemDelete(q as CFDictionary)
        q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(q as CFDictionary, nil)
        log(status == errSecSuccess ? "set" : "set refused", account, status)
        return status == errSecSuccess
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
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status != errSecSuccess, status != errSecItemNotFound {
            log("get refused", account, status)
        }
        guard status == errSecSuccess else { return nil }
        return out as? Data
    }

    static func getString(account: String) -> String? {
        get(account: account).flatMap { String(data: $0, encoding: .utf8) }
    }

    static func remove(account: String) {
        let status = SecItemDelete(query(account: account) as CFDictionary)
        if status != errSecSuccess, status != errSecItemNotFound {
            log("remove refused", account, status)
        }
    }

    static func has(account: String) -> Bool {
        get(account: account) != nil
    }

    // MARK: - Diagnostics

    /// One log line per Keychain operation that touched state (or was refused
    /// unusually). Device test, 2026-10-17: signs-in that reported success did
    /// not survive — this names the raw OSStatus instead of guessing.
    private static func log(_ operation: String, _ account: String, _ status: OSStatus) {
        let level: LogLine.Level = status == errSecSuccess ? .info : .warning
        EngineLogStream.shared.append("[keychain] \(operation) \(account): \(statusName(status))", level: level)
    }

    private static func statusName(_ status: OSStatus) -> String {
        switch status {
        case errSecSuccess: return "ok"
        case errSecItemNotFound: return "item not found (\(status))"
        case errSecMissingEntitlement: return "missing entitlement (\(status))"
        case errSecDuplicateItem: return "duplicate item (\(status))"
        case errSecAuthFailed: return "auth failed (\(status))"
        case errSecNotAvailable: return "not available (\(status))"
        case errSecInteractionNotAllowed: return "interaction not allowed (\(status))"
        default: return "OSStatus \(status)"
        }
    }
}
