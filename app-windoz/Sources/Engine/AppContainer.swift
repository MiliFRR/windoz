import Foundation
import Darwin

/// Where Windoz stores its own files (prefix, library, downloads, staged JIT
/// script). Inside LiveContainer the guest's `NSHomeDirectory()` is *usually*
/// remapped, but not every LiveContainer build does it the same way, so every
/// path goes through here instead of `URL.documentsDirectory`.
enum AppContainer {

    /// Guest home. Prefers `LC_HOME_PATH` (set by LiveContainer before jumping
    /// to the guest entry), then `HOME`, then `NSHomeDirectory()`.
    static var home: URL {
        if let path = environmentPath("LC_HOME_PATH") { return path }
        if let path = environmentPath("HOME") { return URL(fileURLWithPath: path, isDirectory: true) }
        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    }

    static var documents: URL {
        home.appendingPathComponent("Documents", isDirectory: true)
    }

    static var importedGames: URL {
        documents.appendingPathComponent("Imported", isDirectory: true)
    }

    static var runtimes: URL {
        documents.appendingPathComponent("windoz-runtimes", isDirectory: true)
    }

    static var liveContainerSupport: URL {
        documents.appendingPathComponent("LiveContainer", isDirectory: true)
    }

    /// The JIT script LiveContainer's per-app "JIT launch Script" picker should
    /// be pointed at. Copied out of the bundle on bootstrap so it is a real
    /// file the user can select, not a resource URL that Files cannot reach.
    static var stagedJITScript: URL {
        liveContainerSupport.appendingPathComponent("windoz-jit.js")
    }

    static var libraryFile: URL {
        documents.appendingPathComponent("windoz-library.json")
    }

    static var downloadsFile: URL {
        documents.appendingPathComponent("windoz-downloads.json")
    }

    /// Create the folders Windoz needs and stage the JIT script. Safe to call
    /// more than once; never throws into the UI.
    static func bootstrap() {
        let fm = FileManager.default
        for url in [documents, importedGames, runtimes, liveContainerSupport] {
            try? fm.createDirectory(at: url, withIntermediateDirectories: true)
        }
        stageJITScript()
        EngineLogStream.shared.append("[host] \(AppEnvironment.installKind); home=\(home.path)")
        if AppEnvironment.isLiveContainer {
            EngineLogStream.shared.append(
                "[host] LiveContainer: guest bundle \(AppEnvironment.bundleIdentifier), pid \(getpid()), JIT script \(stagedJITScript.path)")
        }
    }

    /// Copy the engine's StikDebug script into Documents so LiveContainer can
    /// load it as a "JIT launch Script". Returns the destination when the copy
    /// succeeded.
    @discardableResult
    static func stageJITScript() -> URL? {
        let destination = stagedJITScript
        let fm = FileManager.default
        if let source = bundledJITScriptURL() {
            if fm.fileExists(atPath: destination.path) {
                try? fm.removeItem(at: destination)
            }
            do {
                try fm.copyItem(at: source, to: destination)
                return destination
            } catch {
                EngineLogStream.shared.append("[host] could not stage JIT script: \(error.localizedDescription)", level: .warning)
            }
        }
        return fm.fileExists(atPath: destination.path) ? destination : nil
    }

    static func bundledJITScriptURL() -> URL? {
        Bundle.main.url(forResource: "windoz-jit", withExtension: "js")
            ?? Bundle.main.url(forResource: "madeira-jit", withExtension: "js")
    }

    private static func environmentPath(_ name: String) -> URL? {
        guard let raw = getenv(name) else { return nil }
        let path = String(cString: raw)
        guard !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }
}
