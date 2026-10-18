import Foundation
import Darwin
import MachO

/// Runtime environment detection. Everything here is real, observable state —
/// nothing is inferred from the build configuration alone.
enum AppEnvironment {

    /// LiveContainer re-hosts the guest inside LiveProcess. Detection uses
    /// several independent signals because not every LiveContainer build
    /// exports the same environment.
    static var isLiveContainer: Bool {
        if getenv("LC_HOME_PATH") != nil { return true }
        if Bundle.main.object(forInfoDictionaryKey: "LCAppInfo") != nil { return true }
        let bundlePath = Bundle.main.bundlePath
        if bundlePath.localizedCaseInsensitiveContains("LiveContainer")
            || bundlePath.localizedCaseInsensitiveContains("LiveProcess") {
            return true
        }
        let parent = (bundlePath as NSString).deletingLastPathComponent
        if FileManager.default.fileExists(atPath: (parent as NSString).appendingPathComponent("LCAppInfo.plist")) {
            return true
        }
        return false
    }

    static var isSimulator: Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }

    /// The live *guest* bundle identifier. On a re-signed sideload (SideStore,
    /// AltStore, Plume, LiveContainer) this differs from the build-time
    /// identifier, so it is always read from `Bundle.main` at run time.
    static var bundleIdentifier: String {
        Bundle.main.bundleIdentifier ?? "com.milifrr.windoz"
    }

    /// The process that actually needs CS_DEBUGGED: LiveProcess when hosted,
    /// otherwise this app. StikDebug attaching by PID uses `getpid()` (already
    /// LiveProcess inside LiveContainer). The bundle id StikDebug shows is the
    /// host's when we can see it, because SpringBoard never registered the guest.
    static var jitTargetBundleIdentifier: String {
        if isLiveContainer, let host = hostExecutableBundleIdentifier, host != bundleIdentifier {
            return host
        }
        return bundleIdentifier
    }

    /// Best-effort LiveProcess / LiveContainer bundle id from the running
    /// executable path. Returns nil when we cannot tell (common: LiveContainer
    /// has already patched `_NSGetExecutablePath` to the guest).
    static var hostExecutableBundleIdentifier: String? {
        var buffer = [CChar](repeating: 0, count: 1024)
        var size = UInt32(buffer.count)
        guard _NSGetExecutablePath(&buffer, &size) == 0 else { return nil }
        let path = String(cString: buffer)
        let url = URL(fileURLWithPath: path)
        for candidate in sequence(first: url.deletingLastPathComponent(), next: { parent in
            let next = parent.deletingLastPathComponent()
            return next.path == parent.path ? nil : next
        }) {
            let plist = candidate.appendingPathComponent("Info.plist")
            guard let info = NSDictionary(contentsOf: plist),
                  let id = info["CFBundleIdentifier"] as? String else { continue }
            if id.localizedCaseInsensitiveContains("livecontainer")
                || id.localizedCaseInsensitiveContains("liveprocess") {
                return id
            }
        }
        return nil
    }

    /// JIT methods that can actually work here, in preference order. The
    /// built-in helper is only offered when its extension really is in the
    /// bundle (`JITManager.builtInHelperUsable`), so the list never promises a
    /// route this build does not have.
    static var availableJITMethods: [JITMethod] {
        if isSimulator { return [] }
        if isLiveContainer { return [.stikDebug] }
        return JITManager.builtInHelperUsable ? [.automatic, .stikDebug, .builtIn] : [.stikDebug]
    }

    /// Why a normally-available feature is limited on this install, if it is.
    static var installKind: String {
        if isSimulator { return "Simulator" }
        if isLiveContainer { return "LiveContainer" }
        return "Sideloaded app"
    }

    /// A short, human explanation of the JIT situation for the setup wizard.
    static var jitSituation: String {
        if isSimulator {
            return "The Simulator cannot enable JIT. Use a real device."
        }
        if isLiveContainer {
            return "Inside LiveContainer, Windoz cannot start a bundled helper extension. Turn on “Launch with JIT” for Windoz in LiveContainer, point its JIT launch Script at Documents/LiveContainer/windoz-jit.js, and use StikDebug (on iOS 26 that is often StikDebug in another LiveContainer)."
        }
        return "JIT needs a debugger attach. Windoz can use StikDebug or its own bundled helper — see Settings › JIT setup."
    }

    /// Features that LiveContainer (or the Simulator) cannot provide. The UI
    /// shows these as unsupported rather than failing later.
    static var hostLimits: [HostLimit] {
        var limits: [HostLimit] = []
        if isSimulator {
            limits.append(HostLimit(title: "JIT",
                                    state: .unavailable("The Simulator cannot enable JIT.")))
        }
        if isLiveContainer {
            limits.append(HostLimit(title: "Bundled JIT helper",
                                    state: .unavailable("App extensions never start inside LiveContainer. Use StikDebug with LiveContainer's Launch with JIT.")))
            limits.append(HostLimit(title: "Increased memory entitlement",
                                    state: .unavailable("LiveContainer does not copy guest entitlements. Large games may be jetsam-killed at the host's memory limit.")))
            limits.append(HostLimit(title: "Live Activities / Dynamic Island",
                                    state: .unavailable("Widget extensions are not registered for guest apps. Download progress stays inside Windoz.")))
            limits.append(HostLimit(title: "Background download tasks",
                                    state: .unavailable("BGTaskScheduler only accepts LiveContainer's own identifiers, not Windoz's. Keep the app open (or in a LiveContainer window) while downloading.")))
            limits.append(HostLimit(title: "Custom URL schemes",
                                    state: .unavailable("SpringBoard never sees the guest's URL schemes. Opening StikDebug from here may still work through LiveContainer's openURL hook.")))
        }
        return limits
    }
}

struct HostLimit: Identifiable, Equatable {
    var title: String
    var state: FeatureState
    var id: String { title }
}
