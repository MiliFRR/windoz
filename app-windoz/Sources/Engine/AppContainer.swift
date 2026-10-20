import Foundation
import Darwin
import Security

/// Where Windoz stores its own files (prefix, library, downloads, staged JIT
/// script). Inside LiveContainer the guest's `NSHomeDirectory()` is *usually*
/// remapped, but not every LiveContainer build does it the same way, so every
/// path goes through here instead of `URL.documentsDirectory`.
///
/// Device history (2026-10-17 → 0.3.5): on the owner's device *Documents*
/// refused every write (Foundation 513, C-library EPERM) while reads and the
/// network kept working — and the Wine prefix was hardcoded inside Documents,
/// so every session died at "storage refused" no matter what the game was.
/// The rule this file now lives by: **nothing is assumed writable**. Every
/// storage decision is made by a real create + write + replace + delete test,
/// once per process, and the Wine environment travels to a location that
/// passes. When literally nothing passes, the refusal message carries the
/// errno and the free space of every candidate instead of a vague "denied".
enum AppContainer {

    /// Shown in Settings → About *and* printed in the first log line, so a
    /// device session can always be matched to a build. Bump this together
    /// with `project.yml`'s MARKETING_VERSION: `scripts/check-ipa.py` fails
    /// the release build when the executable does not carry that literal.
    static let displayVersion = "0.9.0"

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

    // MARK: - Storage negotiation (probing, never assuming)

    /// One location's write verdict, from a real create + write + replace +
    /// delete through Foundation and, when Foundation refuses, the C library.
    /// Probe names are unique every run: this device's container has
    /// "existing items resist replace" episodes, and a leftover probe file
    /// from a previous run must never poison the next test (a fixed probe
    /// name did exactly that before 0.4.0).
    struct WriteVerdict {
        let label: String
        let url: URL
        /// A new file could be created (after creating the folder if needed).
        let createdFile: Bool
        /// An existing file could be replaced — Wine rewrites its registry
        /// hives on every boot, so a container that only accepts *new* files
        /// still cannot run a session.
        let replacedFile: Bool
        let deletedFile: Bool
        /// A one-shot repair (clear BSD flags, open the mode bits) made the
        /// difference.
        let repaired: Bool
        /// The first refusal, verbatim — Foundation error text and/or the C
        /// library's errno.
        let failure: String?

        var usable: Bool { createdFile && replacedFile }

        var summary: String {
            var parts = ["create=\(createdFile ? "yes" : "no")",
                         "replace=\(replacedFile ? "yes" : "no")",
                         "delete=\(deletedFile ? "yes" : "no")"]
            if repaired { parts.append("after-repair") }
            if let failure { parts.append(failure) }
            return parts.joined(separator: " ")
        }
    }

    /// A fresh probe name every call.
    static func probeName(_ tag: String) -> String {
        ".windoz-\(tag)-\(getpid())-\(UInt32(Date().timeIntervalSince1970))-\(UInt32.random(in: 0..<0xffff))"
    }

    /// Probe one directory with the exact operations an install and a Wine
    /// boot run: create a file, replace it, read it back, delete it — through
    /// Foundation first, then the C library. On refusal, one repair pass
    /// (clear BSD flags + open the mode bits) is attempted when the folder is
    /// inside the app's own home, then the test runs once more.
    static func probeWrites(_ directory: URL, label: String) -> WriteVerdict {
        let fm = FileManager.default
        var directoryReady = fm.fileExists(atPath: directory.path)
        var failure: String? = nil

        if !directoryReady {
            if (try? fm.createDirectory(at: directory, withIntermediateDirectories: true)) != nil {
                directoryReady = true
            } else {
                let made = ContainerFS.mkdirs(directory.path)
                if made.ok { directoryReady = true }
                else { failure = "mkdir refused (" + made.lines.joined(separator: "; ") + ")" }
            }
        }
        guard directoryReady else {
            return WriteVerdict(label: label, url: directory, createdFile: false, replacedFile: false,
                                deletedFile: false, repaired: false, failure: failure)
        }

        func round() -> (created: Bool, replaced: Bool, deleted: Bool, failure: String?) {
            let probe = directory.appendingPathComponent(probeName("probe"))
            var created = false, replaced = false, deleted = false
            var firstFailure: String? = nil
            do { try Data([0x57]).write(to: probe); created = true }
            catch {
                let raw = ContainerFS.writeFile(probe.path, Data([0x57]))
                if raw.ok { created = true }
                else { firstFailure = "create refused (Foundation \(describe(error)); C \(raw.detail))" }
            }
            if created {
                do { try Data([0x72]).write(to: probe); replaced = true }
                catch {
                    let raw = ContainerFS.writeFile(probe.path, Data([0x72]))
                    if raw.ok { replaced = true }
                    else if firstFailure == nil { firstFailure = "replace refused (Foundation \(describe(error)); C \(raw.detail))" }
                }
            }
            do {
                try fm.removeItem(at: probe)
                deleted = !fm.fileExists(atPath: probe.path)
            } catch {
                let raw = ContainerFS.unlink(probe.path)
                deleted = raw.ok || !fm.fileExists(atPath: probe.path)
            }
            return (created, replaced, deleted, firstFailure)
        }

        var result = round()
        var repaired = false
        let ours = directory.standardizedFileURL.path.hasPrefix(home.standardizedFileURL.path)
        if ours, !(result.created && result.replaced) {
            let flags = ContainerFS.flags(directory.path) ?? 0
            let mode = ContainerFS.openOwnerAccess(directory.path)
            if flags != 0 || mode.changed {
                let retry = round()
                if retry.created && retry.replaced {
                    repaired = true
                    result = retry
                } else if retry.failure == nil {
                    result = retry
                }
            }
        }
        return WriteVerdict(label: label, url: directory, createdFile: result.created,
                            replacedFile: result.replaced, deletedFile: result.deleted,
                            repaired: repaired, failure: repaired ? nil : result.failure)
    }

    /// Every location the app considers, probed exactly once per process. The
    /// boot audit, the storage root and the Wine prefix all read this one
    /// table, so they can never disagree about what the device allows.
    static let writeMatrix: [WriteVerdict] = {
        var verdicts: [WriteVerdict] = []
        var seen = Set<String>()
        func add(_ label: String, _ url: URL) {
            let key = url.standardizedFileURL.path
            guard seen.insert(key).inserted else { return }
            verdicts.append(probeWrites(url, label: label))
        }
        add("Documents", documents)
        add("Library", libraryRoot)
        add("tmp", temporary)
        add("home root", home)
        if let groups = ownEntitlement("com.apple.security.application-groups") as? [String], !groups.isEmpty {
            for id in groups {
                if let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id) {
                    add("app group \(id)", url)
                }
            }
        }
        add("system temp", URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true))
        add("shared temp", URL(fileURLWithPath: "/private/var/mobile/tmp", isDirectory: true))
        return verdicts
    }()

    /// Where Windoz keeps files it must be able to write *and keep* (the
    /// library index, cover art, store records). Documents first (the layout
    /// every build before 0.3.5 used), then Library, then tmp — each decided
    /// by the probe table, never assumed. The choice is logged so the launch
    /// log always names it.
    static let storageRoot: URL = {
        if let first = writeMatrix.first(where: { $0.usable && ["Documents", "Library", "tmp"].contains($0.label) }) {
            if first.label != "Documents" {
                EngineLogStream.shared.append(
                    "[host] storage root: Documents refused writes — using \(first.label) (\(first.url.path))",
                    level: .warning)
            } else {
                EngineLogStream.shared.append("[host] storage root: \(first.url.path)")
            }
            return first.url
        }
        if let any = writeMatrix.first(where: { $0.usable }) {
            EngineLogStream.shared.append(
                "[host] storage root: Documents, Library and tmp all refused — using \(any.label) (\(any.url.path))",
                level: .warning)
            return any.url
        }
        EngineLogStream.shared.append(
            "[host] storage root: no location accepted a write (\(writeMatrix.map { "\($0.label): \($0.summary)" }.joined(separator: " | "))) — Windoz keeps the Documents path and every save reports its own refusal",
            level: .error)
        return documents
    }()

    /// The directory the Wine prefix lives in. `Documents/windoz-prefix` is
    /// what every build before 0.4.0 used, and it stays the choice whenever
    /// that path accepts writes (most containers do). When it does not — this
    /// device's Documents refuses every write — the prefix travels, as one
    /// unit, to the first location that passes the same create + replace
    /// test: Library, tmp, or an audited root. Wine cannot boot on a folder
    /// it cannot write, so a writable folder is the difference between a
    /// session and a black screen.
    static let prefixBase: URL = {
        let legacyPrefix = documents.appendingPathComponent("windoz-prefix", isDirectory: true)
        let legacyExists = FileManager.default.fileExists(atPath: legacyPrefix.appendingPathComponent("drive_c").path)
        if legacyExists {
            let verdict = probeWrites(legacyPrefix, label: "Documents/windoz-prefix")
            if verdict.usable {
                EngineLogStream.shared.append("[host] prefix home: Documents/windoz-prefix (existing, writable)")
                return documents
            }
            EngineLogStream.shared.append(
                "[host] prefix home: the existing prefix refuses writes (\(verdict.summary)) — looking for a writable home",
                level: .warning)
        } else if let d = writeMatrix.first(where: { $0.label == "Documents" }), d.usable {
            EngineLogStream.shared.append("[host] prefix home: Documents/windoz-prefix")
            return documents
        }
        if let first = writeMatrix.first(where: { $0.usable }) {
            EngineLogStream.shared.append(
                "[host] prefix home: the Windows environment lives at \(first.url.path)/windoz-prefix (\(first.label) accepted writes)",
                level: .warning)
            return first.url
        }
        EngineLogStream.shared.append(
            "[host] prefix home: nothing on this device accepted a write — the prefix stays in Documents and sessions will refuse to start",
            level: .error)
        return documents
    }()

    static var prefixRoot: URL {
        prefixBase.appendingPathComponent("windoz-prefix", isDirectory: true)
    }

    /// Free space on the volume a location lives on, for the storage refusal
    /// text — "out of space" and "permission refused" are different repairs.
    static func freeSpaceDescription(at url: URL = storageRoot) -> String {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let bytes = values?.volumeAvailableCapacityForImportantUsage {
            return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        }
        return "unknown"
    }

    /// One create + write + replace test through Foundation, then through the
    /// C library — the same two-route pattern as the rest of the app. Kept
    /// for callers that predate the probe table; reads the table when the
    /// location was already probed, so answers never disagree.
    static func acceptsWrites(_ directory: URL) -> Bool {
        if let hit = writeMatrix.first(where: { $0.url.standardizedFileURL.path == directory.standardizedFileURL.path }) {
            return hit.usable
        }
        return probeWrites(directory, label: directory.lastPathComponent).usable
    }

    /// Cover art and other small files that must survive a relaunch. Kept at
    /// the resolved storage root, not hardcoded to Documents.
    static var artDirectory: URL {
        let url = storageRoot.appendingPathComponent("windoz-art", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// The library index at the resolved root. `libraryFile` (Documents) stays
    /// as the legacy read fallback.
    static var libraryFilePrimary: URL {
        storageRoot.appendingPathComponent("windoz-library.json")
    }

    /// Create the folders Windoz needs and stage the JIT script. Safe to call
    /// more than once; never throws into the UI.
    static func bootstrap() {
        let fm = FileManager.default
        for url in [documents, importedGames, runtimes, liveContainerSupport, libraryRoot, temporary] {
            try? fm.createDirectory(at: url, withIntermediateDirectories: true)
        }
        stageJITScript()
        EngineLogStream.shared.append("[host] windoz \(displayVersion) \(AppEnvironment.installKind); home=\(home.path); storage=\(storageRoot.path)")
        EngineLogStream.shared.append("[host] free space at storage: \(freeSpaceDescription())")
        _ = prefixBase // triggers the (logged) prefix-home decision once, up front
        if AppEnvironment.isLiveContainer {
            EngineLogStream.shared.append(
                "[host] LiveContainer: guest bundle \(AppEnvironment.bundleIdentifier), pid \(getpid()), JIT script \(stagedJITScript.path)")
        }
        logWriteHealth()
        auditWritableLocations()
    }

    /// End this app run on purpose. Two reasons it exists: Wine hosts one
    /// game session per app process, and a launch that stalls inside the
    /// engine's start-up locks cannot be retried in the same process. Under
    /// LiveContainer there is no easy "force quit" for a guest, so the app
    /// offers the honest one — the owner is always the one pressing it. The
    /// log is flushed first, then the process goes.
    static func quitNow(reason: String) {
        EngineLogStream.shared.append("[host] quitting on purpose: \(reason)", level: .warning)
        EngineLogFile.shared.appendEngineLogTail(reason: "the owner quit the app")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { exit(0) }
    }

    /// Locations beyond the six folders that accepted a real write, in probe
    /// order (home root, app-group containers, temp dirs). Empty when the
    /// device refused everything.
    static private(set) var discoveredRoots: [URL] = []

    /// Device test, 2026-10-17 (build 0.3.2 log): every container folder
    /// refused writes with raw errno 1 (EPERM) through both routes — while
    /// reads and network stayed fine — so no in-folder fallback could ever
    /// work. This audit answers the only question left: is *any* location on
    /// this device writable for Windoz? It reads the same probe table every
    /// storage decision uses, so the log and the decisions always agree.
    static func auditWritableLocations() {
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
        var roots: [URL] = []
        for verdict in writeMatrix {
            if verdict.usable {
                EngineLogStream.shared.append(
                    "[host] write-audit: \(verdict.label) \(verdict.url.path) → writable\(verdict.repaired ? " (after repair)" : "")")
                if !["Documents", "Library", "tmp"].contains(verdict.label) {
                    roots.append(verdict.url)
                }
            } else {
                EngineLogStream.shared.append(
                    "[host] write-audit: \(verdict.label) \(verdict.url.path) → refused (\(verdict.summary))",
                    level: .warning)
            }
        }
        discoveredRoots = roots
        if writeMatrix.contains(where: { $0.usable }) {
            EngineLogStream.shared.append(
                "[host] write-audit: writable roots: \(writeMatrix.filter { $0.usable }.map(\.url.path).joined(separator: ", "))")
        } else {
            EngineLogStream.shared.append(
                "[host] write-audit: no writable location on this device — Windoz cannot store anything until the container is repaired (free space: \(freeSpaceDescription()))",
                level: .error)
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
        for (name, url) in [("Documents", documents), ("Imported", importedGames),
                            ("Runtimes", runtimes), ("LiveContainer", liveContainerSupport),
                            ("Library", libraryRoot), ("tmp", temporary)] {
            if let flags = ContainerFS.flags(url.path), flags != 0 {
                let docPath = documents.standardizedFileURL.path
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
            let verdict = probeWrites(url, label: name)
            if !verdict.createdFile {
                problems.append("\(name) cannot create a file: \(verdict.failure ?? "refused")")
            } else if !verdict.replacedFile {
                problems.append("\(name) refuses to replace an existing file: \(verdict.failure ?? "refused")")
            }
            if !verdict.deletedFile {
                problems.append("\(name) refuses to delete a probe file (\(probeName("probe")))")
            }
        }
        if problems.isEmpty {
            EngineLogStream.shared.append("[host] container write check: all six folders writable (create, replace, delete)")
        } else {
            for line in problems {
                EngineLogStream.shared.append("[host] container write check: \(line)", level: .warning)
            }
        }
    }

    /// First directory named `name` that accepts a real create + write +
    /// replace + delete, tried under each base in order (callers pass
    /// Documents first, then Library, then tmp), then under every writable
    /// location the boot audit found. Every refusal is logged, so the log
    /// names why a fallback was needed.
    static func writableDirectory(named name: String, among bases: [URL]) -> URL? {
        let preferred = documents.standardizedFileURL
        var allBases = bases
        for root in discoveredRoots where !allBases.contains(where: { $0.standardizedFileURL.path == root.standardizedFileURL.path }) {
            allBases.append(root)
        }
        for base in allBases {
            let dir = base.appendingPathComponent(name, isDirectory: true)
            let verdict = probeWrites(dir, label: name)
            if verdict.usable {
                if base.standardizedFileURL != preferred {
                    EngineLogStream.shared.append("[host] \(name): Documents refused — using \(dir.path)")
                }
                return dir
            }
            EngineLogStream.shared.append(
                "[host] \(name): not usable under \(base.lastPathComponent): \(verdict.summary)", level: .warning)
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
