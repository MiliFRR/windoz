import Foundation

/// Runtime environment detection. Everything here is real, observable state —
/// nothing is inferred from the build configuration alone.
enum AppEnvironment {

    /// LiveContainer runs guest apps inside its own process and exports
    /// `LC_HOME_PATH`. Under LiveContainer an app cannot use a bundled app
    /// extension (the built-in JIT helper) and its bundle identifier is not the
    /// one that was built, so JIT must go through StikDebug.
    static var isLiveContainer: Bool {
        getenv("LC_HOME_PATH") != nil
    }

    static var isSimulator: Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }

    /// The live bundle identifier. On a re-signed sideload (SideStore, AltStore,
    /// Plume, LiveContainer) this differs from the build-time identifier, so it
    /// is always read from `Bundle.main` at run time.
    static var bundleIdentifier: String {
        Bundle.main.bundleIdentifier ?? "com.milifrr.windoz"
    }

    /// JIT methods that can actually work here, in preference order.
    static var availableJITMethods: [JITMethod] {
        if isSimulator { return [] }
        if isLiveContainer { return [.stikDebug] }
        return [.automatic, .stikDebug, .builtIn]
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
            return "LiveContainer cannot use Windoz's built-in JIT helper, so JIT must be enabled with the separate StikDebug app."
        }
        return "JIT needs a debugger attach. Windoz can use StikDebug or its own bundled helper."
    }
}
