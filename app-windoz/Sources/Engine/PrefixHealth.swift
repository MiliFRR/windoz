// SPDX-License-Identifier: GPL-3.0-or-later
// Windoz — write-access health for the Steam folders inside the Wine prefix.
//
// Device test, 2026-10-17: creating `steamapps/common/<game>` failed with
// Foundation 513 ("You don't have permission to save the file … in the folder
// “common”"), and the runtime installer hit a permission error moving its file
// into the container. The shipped prefix template is fully owner-writable, so
// the blocker is on the device's own data — a level that is a symlink, a file,
// or missing its owner bits after an earlier install. This is therefore an
// executor, not just a reporter:
//
//   1. report every level — lstat (symlinks, types) plus stat, plus a real
//      write attempt with the raw errno
//   2. rename the first broken level at or below `windoz-prefix` away
//      (kept as `<name>.windoz-broken-<timestamp>` for inspection) so the
//      chain can be rebuilt fresh — nothing above windoz-prefix is touched
//   3. probe the exact operations the downloader runs
//   4. return one honest verdict naming the failing level
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

        var isSound: Bool { exists && !isSymlink && isDirectory && ownerWritable && accessOK }

        var description: String {
            "\(exists ? (isSymlink ? "symlink" : (isDirectory ? "dir" : "file")) : "missing") mode=\(mode) uid=\(uid) \(accessOK ? "w-ok" : "W-DENIED") \(url.path)"
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

    /// Report, repair, probe — and return a one-line verdict for the UI.
    @discardableResult
    static func checkAndRepair(steamApps: URL) -> String {
        var lines: [String] = ["checking \(steamApps.path)"]
        let before = levels(steamApps: steamApps)
        for level in before { lines.append(level.description) }
        for level in before where level.exists && level.isDirectory {
            lines.append("write probe \(level.url.path): \(probe(level.url))")
        }

        // The first broken level at or below windoz-prefix is renamed away and
        // the chain rebuilt. Documents itself is only ever reported.
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
                try FileManager.default.moveItem(at: url, to: moved)
                lines.append("replaced broken level \(url.path) → \(moved.lastPathComponent)")
                repaired = true
            } catch {
                let raw = error as NSError
                lines.append("could not rename \(url.path): \(raw.domain) \(raw.code) — \(raw.localizedDescription)")
            }
            break // rebuilding the first broken level makes the rest moot
        }

        let fm = FileManager.default
        var ok = true
        var failure = ""
        do {
            try fm.createDirectory(at: steamApps, withIntermediateDirectories: true)
            let common = steamApps.appendingPathComponent("common", isDirectory: true)
            try fm.createDirectory(at: common, withIntermediateDirectories: true)
            let probeFile = common.appendingPathComponent(".windoz-write-probe")
            try Data([0x57]).write(to: probeFile)
            try? fm.removeItem(at: probeFile)
            lines.append("probe write to common: OK\(repaired ? " (after repair)" : "")")
        } catch {
            ok = false
            let raw = error as NSError
            failure = "\(raw.domain) \(raw.code) — \(raw.localizedDescription)"
            lines.append("probe failed: \(failure)")
            let after = levels(steamApps: steamApps)
            for level in after { lines.append("after: \(level.description)") }
            if let first = after.first(where: { $0.exists && !$0.isSound }) {
                failure = "blocked at \(first.url.path) — \(first.description)"
            }
        }

        for line in lines {
            EngineLogStream.shared.append("[prefix-health] \(line)", level: ok ? .info : .warning)
            BootTrace.mark("[prefix-health] \(line)")
        }
        return ok
            ? "Windows-prefix write path: OK — steamapps/common is writable." + (repaired ? " (A broken folder was replaced.)" : "")
            : "Windows-prefix write path: FAILED — \(failure)"
    }

    // MARK: - low level

    /// One real write attempt inside `url`; returns "OK" or the raw errno.
    private static func probe(_ url: URL) -> String {
        var st = stat()
        guard url.withUnsafeFileSystemRepresentation({ lstat($0, &st) == 0 }),
              (st.st_mode & S_IFMT) == S_IFDIR else { return "not a directory" }
        let file = url.appendingPathComponent(".windoz-probe-\(getpid())")
        let fd = creat(file.path, 0o644)
        if fd < 0 {
            let err = errno
            return "create failed: errno \(err) (\(String(cString: strerror(err))))"
        }
        _ = close(fd)
        _ = unlink(file.path)
        return "OK"
    }

    private static func inspect(_ url: URL) -> Level {
        var lst = stat()
        let exists = url.withUnsafeFileSystemRepresentation { lstat($0, &lst) == 0 }
        let isSymlink = exists && (lst.st_mode & S_IFMT) == S_IFLNK
        var st = stat()
        let follows = url.withUnsafeFileSystemRepresentation { stat($0, &st) == 0 }
        let accessOK = url.withUnsafeFileSystemRepresentation { access($0, W_OK) == 0 }
        let mode = (follows ? st.st_mode : lst.st_mode) & 0o7777
        return Level(url: url,
                     exists: exists,
                     isSymlink: isSymlink,
                     isDirectory: follows && (st.st_mode & S_IFMT) == S_IFDIR,
                     ownerWritable: follows && (st.st_mode & 0o200) != 0,
                     accessOK: accessOK,
                     mode: String(format: "%o", mode),
                     uid: follows ? st.st_uid : (exists ? lst.st_uid : 0))
    }
}
