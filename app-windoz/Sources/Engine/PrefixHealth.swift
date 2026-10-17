// SPDX-License-Identifier: GPL-3.0-or-later
// Windoz — write-access health for the Steam folders inside the Wine prefix.
//
// Device test, 2026-10-17: creating `steamapps/common/<game>` failed with
// Foundation 513 ("You don't have permission to save the file … in the folder
// “common”"), and the runtime installer hit a permission error moving its file
// into the container. The shipped prefix template is fully owner-writable, and
// the device's own report later showed every level of the path as
// `mode=755 uid=501 owner-w` — yet Foundation's create was refused while
// "Steam" was reported missing before *and* after the attempt. This is
// therefore an executor, not just a reporter:
//
//   1. report every level — lstat (symlinks, types, raw errno, BSD flags)
//      plus stat, plus access(W_OK); a set flag on a level at or below
//      Documents is cleared first (an immutable bit blocks creates and
//      deletes no matter the mode bits), and the outcome is reported
//   2. probe each level with real operations through *both* routes —
//      Foundation (Data.write + removeItem) and the C library
//      (creat/mkdir + unlink/rmdir) — so a route that refuses names itself
//   3. rename the first broken level at or below `windoz-prefix` away
//      (kept as `<name>.windoz-broken-<timestamp>` for inspection) so the
//      chain can be rebuilt fresh — nothing above windoz-prefix is touched
//   4. rebuild the chain, Foundation first then the C library; when even
//      that is refused and the refusal is inside the prefix (and the engine
//      is not running), rename the whole prefix aside and extract a fresh
//      template — the old tree is kept for inspection
//   5. show what is actually on disk at the failing level (names, types,
//      BSD flags) through the C library's own readdir
//   6. return one honest verdict naming the failing level and route
//
// Every line also goes to the engine log (exportable from Settings) and the
// boot trace, so a failing run still names its cause.

import Foundation
import Darwin

enum PrefixHealth {

    struct Level: CustomStringConvertible {
        let url: URL
        let exists: Bool            // lstat — a dangling symlink counts as existing
        let isSymlink: Bool
        let isDirectory: Bool       // stat (follows links)
        let ownerWritable: Bool
        let accessOK: Bool          // access(W_OK)
        let mode: String
        let uid: uid_t
        let flags: UInt32           // st_flags (UF_IMMUTABLE = 0x2, SF_IMMUTABLE = 0x80000)
        let lstatErrno: Int32

        var isSound: Bool { exists && !isSymlink && isDirectory && ownerWritable && accessOK }

        var description: String {
            var text: String
            if exists {
                text = isSymlink ? "symlink" : (isDirectory ? "dir" : "file")
            } else {
                text = "missing (lstat errno \(lstatErrno): \(String(cString: strerror(lstatErrno))))"
            }
            text += " mode=\(mode) uid=\(uid)"
            if flags != 0 { text += " flags=0x\(String(flags, radix: 16))" }
            text += " \(accessOK ? "w-ok" : "W-DENIED") \(url.path)"
            return text
        }
    }

    static func prefixRoot() -> URL {
        AppContainer.documents.appendingPathComponent("windoz-prefix", isDirectory: true)
    }

    /// Documents → windoz-prefix → … → steamapps → common, outermost first.
    static func levels(steamApps: URL) -> [Level] {
        var urls: [URL] = [steamApps.appendingPathComponent("common", isDirectory: true)]
        let stop = AppContainer.documents.standardizedFileURL
        var current = steamApps.standardizedFileURL
        while true {
            urls.insert(current, at: 0)
            if current == stop { break }
            let parent = current.deletingLastPathComponent().standardizedFileURL
            if parent.path == current.path { break }
            current = parent
        }
        return urls.map(inspect)
    }

    /// Report, repair, rebuild, probe — and return a one-line verdict for the UI.
    @discardableResult
    static func checkAndRepair(steamApps: URL) -> String {
        let fm = FileManager.default
        var lines: [String] = ["checking \(steamApps.path)",
                               "process uid=\(getuid()) euid=\(geteuid()) pid=\(getpid())"]

        // 1. Every level: type, rights, flags — then one real operation pair.
        var before = levels(steamApps: steamApps)
        for level in before { lines.append(level.description) }
        // 1b. A set BSD flag (immutable and friends) blocks creates and
        //     deletes no matter the mode bits. Anything at or below our
        //     Documents folder is ours to clear; refusals are reported —
        //     clearing SF_IMMUTABLE would need root. The probe pass below
        //     then reports the truth after the repair.
        let docPath = AppContainer.documents.standardizedFileURL.path
        for (index, level) in before.enumerated() where level.exists && level.flags != 0 {
            let url = level.url.standardizedFileURL
            guard url.path == docPath || url.path.hasPrefix(docPath + "/") else {
                lines.append("\(url.path) carries flags=0x\(String(level.flags, radix: 16)) — left alone (outside the app's Documents folder)")
                continue
            }
            let cleared = ContainerFS.clearFlags(url.path)
            if cleared.ok, (ContainerFS.flags(url.path) ?? 1) == 0 {
                before[index] = inspect(level.url)
                lines.append("cleared BSD flags=0x\(String(level.flags, radix: 16)) on \(url.path)")
            } else {
                lines.append("could not clear BSD flags=0x\(String(level.flags, radix: 16)) on \(url.path): \(cleared.detail)")
            }
        }
        var failing: [(url: URL, detail: String)] = []
        for level in before where level.exists && level.isDirectory {
            let probe = dualProbe(level.url)
            lines.append("probe \(level.url.path): \(probe.text)")
            if !probe.ok { failing.append((level.url, probe.text)) }
        }

        // 2. The first broken level at or below windoz-prefix is renamed away
        //    and the chain rebuilt. Documents itself is only ever reported.
        let floor = prefixRoot().standardizedFileURL
        var repaired = false
        for level in before where level.exists && !level.isSound {
            let url = level.url.standardizedFileURL
            guard url.path == floor.path || url.path.hasPrefix(floor.path + "/") else {
                lines.append("leaving \(url.path) alone (above windoz-prefix)")
                continue
            }
            let moved = url.deletingLastPathComponent()
                .appendingPathComponent("\(url.lastPathComponent).windoz-broken-\(Int(Date().timeIntervalSince1970))")
            do {
                try fm.moveItem(at: url, to: moved)
                lines.append("replaced broken level \(url.path) → \(moved.lastPathComponent)")
                repaired = true
            } catch {
                lines.append("could not rename \(url.path): \(describe(error))")
            }
            break // rebuilding the first broken level makes the rest moot
        }

        // 3. Build the real chain — Foundation first, then the C library — and
        //    prove it with a real write.
        let common = steamApps.appendingPathComponent("common", isDirectory: true)
        var route = ""
        func attemptChain() -> Bool {
            route = ""
            do {
                try fm.createDirectory(at: common, withIntermediateDirectories: true)
                route = "Foundation"
            } catch {
                lines.append("Foundation chain create refused: \(describe(error))")
                let dirs = ContainerFS.mkdirs(common.path)
                guard dirs.ok else {
                    lines.append(contentsOf: dirs.lines)
                    return false
                }
                route = "C library"
            }
            let probeFile = common.appendingPathComponent(".windoz-write-probe")
            do {
                try Data([0x57]).write(to: probeFile)
                try? fm.removeItem(at: probeFile)
                route += " write"
                return true
            } catch {
                lines.append("Foundation probe write refused: \(describe(error))")
            }
            let raw = ContainerFS.writeFile(probeFile.path, Data([0x57]))
            guard raw.ok else {
                lines.append("C-library probe write refused: \(raw.detail)")
                return false
            }
            _ = ContainerFS.unlink(probeFile.path)
            route += " mkdirs + C-library write"
            return true
        }
        var writable = attemptChain()

        // 4. Last resort while the refusal is inside the prefix: rename the
        //    whole prefix aside and extract a fresh template. Guarded so a
        //    running engine is never rebuilt from under, and skipped when the
        //    container itself (Documents) is the thing refusing writes.
        var rebuilt = false
        if !writable {
            let rootProbe = AppContainer.documents.appendingPathComponent(".windoz-root-probe")
            let containerOK = ContainerFS.writeFile(rootProbe.path, Data([0x57])).ok
            _ = ContainerFS.unlink(rootProbe.path)
            let insidePrefix = failing.contains { $0.url.path == floor.path || $0.url.path.hasPrefix(floor.path + "/") }
            if !containerOK {
                lines.append("writes are refused outside the prefix too — not rebuilding it")
            } else if !insidePrefix {
                lines.append("nothing inside the prefix refused — not rebuilding it")
            } else if wineserver_is_ready() == 1 {
                lines.append("the engine is running — not rebuilding the prefix from under it")
            } else {
                let moved = floor.deletingLastPathComponent()
                    .appendingPathComponent("windoz-prefix.windoz-broken-\(Int(Date().timeIntervalSince1970))")
                do {
                    try fm.moveItem(at: floor, to: moved)
                    lines.append("old prefix kept at \(moved.lastPathComponent)")
                    try PrefixManager().createIfNeeded()
                    rebuilt = true
                    lines.append("fresh prefix extracted")
                } catch {
                    lines.append("could not rebuild the prefix: \(describe(error))")
                }
            }
            if rebuilt {
                before = levels(steamApps: steamApps)
                lines.append("after the rebuild:")
                for level in before { lines.append(level.description) }
                writable = attemptChain()
            }
        }

        // 5. Show what is actually on disk at the failing levels — through the
        //    C library's readdir — so the report names reality, not a guess.
        if !failing.isEmpty {
            var seen = Set<String>()
            for failure in failing.prefix(3) where seen.insert(failure.url.path).inserted {
                let listing = ContainerFS.children(failure.url.path)
                if listing.ok {
                    let names = listing.entries.map { entry in
                        entry.flags != 0
                            ? "\(entry.name)[\(entry.type), flags=0x\(String(entry.flags, radix: 16))]"
                            : "\(entry.name)[\(entry.type)]"
                    }
                    lines.append("contents of \(failure.url.path): \(names.isEmpty ? "(empty)" : names.joined(separator: ", "))")
                } else {
                    lines.append("contents of \(failure.url.path): readdir refused: errno \(listing.errnoValue) (\(String(cString: strerror(listing.errnoValue))))")
                }
            }
        }

        let summary: String
        if writable {
            summary = "Windows-prefix write path: OK — steamapps/common is writable (\(route))."
                + (repaired ? " A broken folder was replaced." : "")
                + (rebuilt ? " The prefix was rebuilt." : "")
        } else if let first = failing.first {
            var text = "Windows-prefix write path: FAILED — \(first.url.path): \(first.detail) The full per-level report is in the log."
            if first.url.standardizedFileURL.path == AppContainer.documents.standardizedFileURL.path {
                text += " The refusal is in the app's own data folder itself — nothing inside the app can store files until its container is repaired (reinstalling LiveContainer and re-adding Windoz normally rebuilds it)."
            }
            summary = text
        } else {
            summary = "Windows-prefix write path: FAILED — creating steamapps/common was refused; the log names every level, route and errno."
        }
        for line in lines {
            EngineLogStream.shared.append("[prefix-health] \(line)", level: writable ? .info : .warning)
            BootTrace.mark("[prefix-health] \(line)")
        }
        return summary
    }

    // MARK: - low level

    /// One real operation pair inside `url`, through both routes: the C library
    /// (`creat`/`mkdir` + `unlink`/`rmdir`) and Foundation (`Data.write` +
    /// `removeItem`). A route that refuses contributes its raw error.
    private static func dualProbe(_ url: URL) -> (text: String, ok: Bool) {
        var parts: [String] = []
        var ok = true

        let file = url.appendingPathComponent(".windoz-probe-\(getpid())")
        let made = ContainerFS.writeFile(file.path, Data([0x57]))
        if made.ok {
            let gone = ContainerFS.unlink(file.path)
            if gone.ok { parts.append("file C-library=ok") }
            else { parts.append("file C-library delete=\(gone.detail)"); ok = false }
        } else {
            parts.append("file C-library=\(made.detail)"); ok = false
        }

        let dir = url.appendingPathComponent(".windoz-probe-dir-\(getpid())")
        let dirMade = ContainerFS.mkdir(dir.path)
        if dirMade.ok {
            let gone = ContainerFS.rmdir(dir.path)
            if gone.ok { parts.append("dir C-library=ok") }
            else { parts.append("dir C-library rmdir=\(gone.detail)"); ok = false }
        } else {
            parts.append("dir C-library=\(dirMade.detail)"); ok = false
        }

        let foundation = url.appendingPathComponent(".windoz-probe-f-\(getpid())")
        do {
            try Data([0x57]).write(to: foundation)
            do {
                try FileManager.default.removeItem(at: foundation)
                parts.append("file Foundation=ok")
            } catch {
                parts.append("file Foundation delete=\(describe(error))"); ok = false
            }
        } catch {
            parts.append("file Foundation=\(describe(error))"); ok = false
        }

        return (parts.joined(separator: "; "), ok)
    }

    private static func describe(_ error: Error) -> String {
        let raw = error as NSError
        return "\(raw.domain) \(raw.code) — \(raw.localizedDescription)"
    }

    private static func inspect(_ url: URL) -> Level {
        var lst = stat()
        let exists = url.withUnsafeFileSystemRepresentation { lstat($0, &lst) == 0 }
        let lstatErrno: Int32 = exists ? 0 : errno
        let isSymlink = exists && (lst.st_mode & S_IFMT) == S_IFLNK
        var st = stat()
        let follows = url.withUnsafeFileSystemRepresentation { stat($0, &st) == 0 }
        let accessOK = url.withUnsafeFileSystemRepresentation { access($0, W_OK) == 0 }
        let mode = (follows ? st.st_mode : lst.st_mode) & 0o7777
        let flags = exists ? lst.st_flags : (follows ? st.st_flags : 0)
        return Level(url: url,
                     exists: exists,
                     isSymlink: isSymlink,
                     isDirectory: follows && (st.st_mode & S_IFMT) == S_IFDIR,
                     ownerWritable: follows && (st.st_mode & 0o200) != 0,
                     accessOK: accessOK,
                     mode: String(format: "%o", mode),
                     uid: follows ? st.st_uid : (exists ? lst.st_uid : 0),
                     flags: flags,
                     lstatErrno: lstatErrno)
    }
}
