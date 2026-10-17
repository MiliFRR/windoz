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
        if let path = environmentPath("HOME") { return path }
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
        logWriteHealth()
    }

    /// One write probe per container folder at launch — through Foundation and
    /// through the C library, including deletes and BSD flags: if a device's
    /// data folder is not writable (or cannot replace an existing file), this
    /// names it at the top of the log instead of leaving a mystery 513 for a
    /// later download to trip over.
    private static func logWriteHealth() {
        var problems: [String] = []
        for (name, url) in [("Documents", documents), ("Imported", importedGames),
                            ("Runtimes", runtimes), ("LiveContainer", liveContainerSupport)] {
            let probe = url.appendingPathComponent(".windoz-write-probe")
            // Foundation: write, delete, and replace a real file.
            do {
                try Data([0x57]).write(to: probe)
            } catch {
                problems.append("\(name) Foundation write refused: \(describe(error))")
            }
            do { try FileManager.default.removeItem(at: probe) } catch {
                if FileManager.default.fileExists(atPath: probe.path) {
                    problems.append("\(name) Foundation delete refused: \(describe(error))")
                }
            }
            // The C library: create, write, delete.
            let raw = ContainerFS.writeFile(probe.path, Data([0x57]))
            if !raw.ok {
                problems.append("\(name) C-library write refused: \(raw.detail)")
            } else if !ContainerFS.unlink(probe.path).ok {
                problems.append("\(name) C-library delete refused")
            }
            if let flags = ContainerFS.flags(url.path), flags != 0 {
                problems.append("\(name) carries BSD flags=0x\(String(flags, radix: 16)) (the immutable bit blocks creates and deletes)")
            }
        }
        if problems.isEmpty {
            EngineLogStream.shared.append("[host] container write check: all four folders writable")
        } else {
            for line in problems {
                EngineLogStream.shared.append("[host] container write check: \(line)", level: .warning)
            }
        }
    }

    /// Copy the engine's StikDebug script into Documents so LiveContainer can
    /// load it as a "JIT launch Script". Returns the destination when the copy
    /// succeeded or the previous staged copy is still usable.
    ///
    /// Device test, 2026-10-17: an existing staged script could not be deleted
    /// — the copy then answered "an item with the same name already exists" —
    /// the same "existing items resist replace" behaviour the prefix showed.
    /// The replace now falls back to renaming the old copy aside, then to a
    /// C-library write, and every refusal is logged with its raw error.
    @discardableResult
    static func stageJITScript() -> URL? {
        let destination = stagedJITScript
        let fm = FileManager.default
        if let source = bundledJITScriptURL() {
            if fm.fileExists(atPath: destination.path) {
                do {
                    try fm.removeItem(at: destination)
                } catch {
                    EngineLogStream.shared.append("[host] JIT script replace: delete refused: \(describe(error))", level: .warning)
                    let aside = destination.appendingPathExtension("old-\(Int(Date().timeIntervalSince1970))")
                    do {
                        try fm.moveItem(at: destination, to: aside)
                        EngineLogStream.shared.append("[host] JIT script replace: old copy kept as \(aside.lastPathComponent)")
                    } catch {
                        EngineLogStream.shared.append("[host] JIT script replace: rename refused: \(describe(error))", level: .warning)
                    }
                }
            }
            if fm.fileExists(atPath: destination.path) {
                EngineLogStream.shared.append("[host] JIT script stays: the existing copy could not be replaced", level: .warning)
            } else {
                do {
                    try fm.copyItem(at: source, to: destination)
                    return destination
                } catch {
                    EngineLogStream.shared.append("[host] could not stage JIT script: \(describe(error))", level: .warning)
                    if let data = try? Data(contentsOf: source), ContainerFS.writeFile(destination.path, data).ok {
                        EngineLogStream.shared.append("[host] JIT script staged via the C library")
                        return destination
                    }
                }
            }
        }
        return fm.fileExists(atPath: destination.path) ? destination : nil
    }

    private static func describe(_ error: Error) -> String {
        let raw = error as NSError
        return "\(raw.domain) \(raw.code) — \(raw.localizedDescription)"
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
