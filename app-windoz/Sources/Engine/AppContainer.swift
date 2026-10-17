import Foundation
import Darwin
import Security

/// Where Windoz stores its own files (prefix, library, downloads, staged JIT
/// script). Inside LiveContainer the guest's `NSHomeDirectory()` is *usually*
/// remapped, but not every LiveContainer build does it the same way, so every
/// path goes through here instead of `URL.documentsDirectory`.
enum AppContainer {

    /// Shown in Settings → About *and* printed in the first log line, so a
    /// device session can always be matched to a build.
    static let displayVersion = "0.3.4"

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

    /// `Library` and `tmp` — siblings of Documents. Device test, 2026-10-17:
    /// a container can refuse writes *inside Documents itself* (its own
    /// diagnostics reported the folder as W-DENIED) while CFNetwork still
    /// wrote its download temp file — so these two are probed as last-resort
    /// homes for staging that does not have to sit in Documents.
    static var libraryRoot: URL {
        home.appendingPathComponent("Library", isDirectory: true)
    }

    static var temporary: URL {
        home.appendingPathComponent("tmp", isDirectory: true)
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
        for url in [documents, importedGames, runtimes, liveContainerSupport, libraryRoot, temporary] {
            try? fm.createDirectory(at: url, withIntermediateDirectories: true)
        }
        stageJITScript()
        EngineLogStream.shared.append("[host] windoz \(displayVersion) \(AppEnvironment.installKind); home=\(home.path)")
        if AppEnvironment.isLiveContainer {
            EngineLogStream.shared.append(
                "[host] LiveContainer: guest bundle \(AppEnvironment.bundleIdentifier), pid \(getpid()), JIT script \(stagedJITScript.path)")
        }
        logWriteHealth()
        auditWritableLocations()
    }

    /// Locations beyond the six folders that accepted a real write, in probe
    /// order (home root, app-group containers, temp dirs). Empty when the
    /// device refused everything.
    static private(set) var discoveredRoots: [URL] = []

    /// Device test, 2026-10-17 (build 0.3.2 log): every container folder
    /// refused writes with raw errno 1 (EPERM) through both routes — while
    /// reads and network stayed fine — so no in-folder fallback could ever
    /// work. This audit answers the only question left: is *any* location on
    /// this device writable for Windoz? Each probe is logged, and the
    /// writable ones are offered to installer staging and to the
    /// Steam-library fallbacks. "None writable" is itself the answer the
    /// next log needs to carry.
    static func auditWritableLocations() {
        var roots: [URL] = []

        func probe(_ label: String, _ directory: URL) {
            let probe = directory.appendingPathComponent(".windoz-audit-\(getpid())")
            do {
                try Data([0x57]).write(to: probe)
                try? FileManager.default.removeItem(at: probe)
                roots.append(directory)
                EngineLogStream.shared.append("[host] write-audit: \(label) \(directory.path) → writable")
                return
            } catch {
                let raw = ContainerFS.writeFile(probe.path, Data([0x57]))
                if raw.ok {
                    _ = ContainerFS.unlink(probe.path)
                    roots.append(directory)
                    EngineLogStream.shared.append("[host] write-audit: \(label) \(directory.path) → writable (C-library route)")
                } else {
                    EngineLogStream.shared.append(
                        "[host] write-audit: \(label) \(directory.path) → refused (\(describe(error)); C library \(raw.detail))",
                        level: .warning)
                }
            }
        }

        EngineLogStream.shared.append(
            "[host] write-audit: TMPDIR=\(ProcessInfo.processInfo.environment["TMPDIR"] ?? "(unset)") NSTemporaryDirectory=\(NSTemporaryDirectory())")
        let env = ProcessInfo.processInfo.environment.filter { key, _ in
            let upper = key.uppercased()
            return upper.hasPrefix("LC") || upper.contains("SHARED") || upper.contains("CONTAINER")
                || upper.contains("HOME") || upper.contains("TMP")
        }
        if !env.isEmpty {
            EngineLogStream.shared.append(
                "[host] write-audit env: " + env.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))
        }
        probe("home root", home)
        if let groups = ownEntitlement("com.apple.security.application-groups") as? [String], !groups.isEmpty {
            for id in groups {
                if let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id) {
                    probe("app group \(id)", url)
                } else {
                    EngineLogStream.shared.append(
                        "[host] write-audit: app group \(id) has no container on this device", level: .warning)
                }
            }
        } else {
            EngineLogStream.shared.append("[host] write-audit: no application-groups entitlement")
        }
        probe("system temp", URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true))
        probe("shared temp", URL(fileURLWithPath: "/private/var/mobile/tmp", isDirectory: true))

        discoveredRoots = roots
        if roots.isEmpty {
            EngineLogStream.shared.append(
                "[host] write-audit: no writable location on this device — Windoz cannot store anything until the container is repaired",
                level: .error)
        } else {
            EngineLogStream.shared.append("[host] write-audit: writable roots: \(roots.map(\.path).joined(separator: ", "))")
        }
    }

    /// The current process's own entitlement value — LiveContainer's, since
    /// the guest runs inside it. The SecTask functions exist in the Security
    /// framework on every iOS version Windoz runs on, but are not declared in
    /// the iOS SDK, so they are looked up at runtime instead of guessed.
    static func ownEntitlement(_ key: String) -> Any? {
        typealias CreateFn = @convention(c) (CFAllocator?) -> CFTypeRef?
        typealias CopyFn = @convention(c) (CFTypeRef, CFString, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> CFTypeRef?
        guard let handle = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_NOW),
              let createSymbol = dlsym(handle, "SecTaskCreateFromSelf"),
              let copySymbol = dlsym(handle, "SecTaskCopyValueForEntitlement") else { return nil }
        let create = unsafeBitCast(createSymbol, to: CreateFn.self)
        let copy = unsafeBitCast(copySymbol, to: CopyFn.self)
        guard let task = create(nil) else { return nil }
        return copy(task, key as CFString, nil)
    }

    /// One write probe per container folder at launch — through Foundation and
    /// through the C library, including deletes and BSD flags: if a device's
    /// data folder is not writable (or cannot replace an existing file), this
    /// names it at the top of the log instead of leaving a mystery 513 for a
    /// later download to trip over. A set immutable flag is cleared first when
    /// the folder is ours (at or below Documents): it blocks creates and
    /// deletes no matter the mode bits, and clearing `UF_IMMUTABLE` needs only
    /// our own write permission.
    private static func logWriteHealth() {
        var problems: [String] = []
        let docPath = documents.standardizedFileURL.path
        for (name, url) in [("Documents", documents), ("Imported", importedGames),
                            ("Runtimes", runtimes), ("LiveContainer", liveContainerSupport),
                            ("Library", libraryRoot), ("tmp", temporary)] {
            let probe = url.appendingPathComponent(".windoz-write-probe")
            if let flags = ContainerFS.flags(url.path), flags != 0 {
                let path = url.standardizedFileURL.path
                if (path == docPath || path.hasPrefix(docPath + "/")),
                   ContainerFS.clearFlags(url.path).ok,
                   (ContainerFS.flags(url.path) ?? 1) == 0 {
                    EngineLogStream.shared.append(
                        "[host] container write check: cleared BSD flags=0x\(String(flags, radix: 16)) on \(name)")
                } else {
                    problems.append("\(name) carries BSD flags=0x\(String(flags, radix: 16)) (the immutable bit blocks creates and deletes)")
                }
            }
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
        }
        if problems.isEmpty {
            EngineLogStream.shared.append("[host] container write check: all six folders writable")
        } else {
            for line in problems {
                EngineLogStream.shared.append("[host] container write check: \(line)", level: .warning)
            }
        }
    }

    /// First directory named `name` that accepts a real create + write +
    /// delete, tried under each base in order (callers pass Documents first,
    /// then Library, then tmp), then under every writable location the boot
    /// audit found. Foundation is tried per base first, then the C library —
    /// the same dual-route pattern as everywhere else. Every refusal is
    /// logged, so the log names why a fallback was needed.
    static func writableDirectory(named name: String, among bases: [URL]) -> URL? {
        let fm = FileManager.default
        let preferred = documents.standardizedFileURL
        var allBases = bases
        for root in discoveredRoots where !allBases.contains(where: { $0.standardizedFileURL.path == root.standardizedFileURL.path }) {
            allBases.append(root)
        }
        for base in allBases {
            let dir = base.appendingPathComponent(name, isDirectory: true)
            let probe = dir.appendingPathComponent(".windoz-probe-\(getpid())")
            var works = false
            do {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                do {
                    try Data([0x57]).write(to: probe)
                    try? fm.removeItem(at: probe)
                    works = true
                } catch {
                    EngineLogStream.shared.append(
                        "[host] \(name): Foundation write refused in \(base.lastPathComponent): \(describe(error))", level: .warning)
                }
            } catch {
                EngineLogStream.shared.append(
                    "[host] \(name): Foundation mkdir refused in \(base.lastPathComponent): \(describe(error))", level: .warning)
            }
            if !works {
                let dirs = ContainerFS.mkdirs(dir.path)
                if dirs.ok {
                    let raw = ContainerFS.writeFile(probe.path, Data([0x57]))
                    if raw.ok {
                        _ = ContainerFS.unlink(probe.path)
                        works = true
                    } else {
                        EngineLogStream.shared.append(
                            "[host] \(name): C-library write refused in \(base.lastPathComponent): \(raw.detail)", level: .warning)
                    }
                } else {
                    EngineLogStream.shared.append("[host] \(name): \(dirs.lines.joined(separator: "; "))", level: .warning)
                }
            }
            if works {
                if base.standardizedFileURL != preferred {
                    EngineLogStream.shared.append("[host] \(name): Documents refused — using \(dir.path)", level: .warning)
                }
                return dir
            }
        }
        return nil
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
