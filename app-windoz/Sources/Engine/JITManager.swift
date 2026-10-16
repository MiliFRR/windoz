import Foundation
import Darwin

/// Everything about "can this process run translated code".
///
/// On a jailed iPhone, executable memory a *generated* (JIT) process writes is
/// only allowed while a debugger is attached and has flipped CS_DEBUGGED. Windoz
/// can get that attach two ways: the separate StikDebug app, or (when not under
/// LiveContainer) its own bundled helper extension. Both send the same
/// `madeira-jit.js` script, which the engine's `jit26_*` BRK protocol needs.
enum JITManager {

    /// True when executable memory is actually usable right now. We trust the
    /// live probe first: `jit_check_debugged()` stays set even after a debugger
    /// detaches, so the sticky flag alone is not proof.
    static func probeEnabled() -> Bool {
        if windoz_jit_probe() != 0 { return true }
        return jit_check_debugged()
    }

    /// Whether the bundled helper extension may be used here. It has to be
    /// genuinely present in the bundle: the extension is not part of this build
    /// yet, and inside LiveContainer — where the guest app runs in LiveContainer's
    /// own process — a nested extension can never be started anyway. The answer
    /// therefore comes from the bundle, never from the build configuration.
    static var builtInHelperUsable: Bool {
        guard !AppEnvironment.isLiveContainer, !AppEnvironment.isSimulator else { return false }
        guard let plugins = Bundle.main.builtInPlugInsURL,
              let items = try? FileManager.default.contentsOfDirectory(
                at: plugins, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        else { return false }
        return !items.isEmpty
    }

    /// The `stikdebug://enable-jit` URL for this process. StikDebug is given
    /// Windoz's live bundle identifier, this PID and the engine's script.
    static func stikDebugEnableURL() -> URL? {
        var components = URLComponents()
        components.scheme = "stikdebug"
        components.host = "enable-jit"
        var items = [
            URLQueryItem(name: "bundle-id", value: AppEnvironment.bundleIdentifier),
            URLQueryItem(name: "pid", value: String(getpid())),
        ]
        if let script = jitScriptBase64() {
            items.append(URLQueryItem(name: "script-data", value: script))
        }
        components.queryItems = items
        return components.url
    }

    /// The bundled engine script (`madeira-jit.js`), base64 encoded, or nil when
    /// the resource is missing (StikDebug then enables JIT without the custom
    /// script — enough to run, but not the full BRK region protocol).
    static func jitScriptBase64() -> String? {
        guard let url = Bundle.main.url(forResource: "windoz-jit", withExtension: "js")
            ?? Bundle.main.url(forResource: "madeira-jit", withExtension: "js"),
              let data = try? Data(contentsOf: url) else { return nil }
        return data.base64EncodedString()
    }

    // MARK: - Memory entitlement

    /// `limit_bytes_remaining` from TASK_VM_INFO is only meaningful when the
    /// kernel applied a raised limit; zero means "nothing reported".
    static func memoryLimitBytes() -> Int64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let remaining = Int64(info.limit_bytes_remaining)
        return remaining > 0 ? remaining : nil
    }

    static func availableMemoryBytes() -> UInt64 {
        jit_available_memory()
    }

    /// The increased-memory entitlement is granted by the signing profile and
    /// cannot be added by Windoz at run time.
    static var memoryEntitlementHealth: EngineHealth {
        if let limit = memoryLimitBytes() {
            let gib = Double(limit) / 1_073_741_824.0
            if limit > 1_500_000_000 {
                return .ready
            }
            return .unavailable("This signing grants only about \(String(format: "%.1f", gib)) GB of memory. The increased-memory limit needs a signing profile that includes it (not available via LiveContainer).")
        }
        return .unavailable("The increased-memory entitlement is not active in this signing, so large games will be killed by iOS. Add it to the provisioning profile, or accept the standard limit.")
    }

    // MARK: - Signing certificate expiry

    /// Best-effort expiry of the embedded provisioning profile, so the UI can
    /// warn before a 7-day free-Apple-ID re-sign lapses.
    static func signingExpiryDate() -> Date? {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .isoLatin1),
              let start = text.range(of: "<?xml"),
              let end = text.range(of: "</plist>") else { return nil }
        let xml = String(text[start.lowerBound..<end.upperBound])
        guard let plistData = xml.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil) as? [String: Any],
              let expiry = plist["ExpirationDate"] as? Date else { return nil }
        return expiry
    }
}
