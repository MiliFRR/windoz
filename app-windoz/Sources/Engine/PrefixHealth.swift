// SPDX-License-Identifier: GPL-3.0-or-later
// Windoz — write-access health for the Steam folders inside the Wine prefix.
//
// A device test (2026-10-17) hit Foundation error 513 —
// "You don't have permission to save the file … in the folder “common”" —
// when the downloader created `steamapps/common/<game>`. The shipped prefix
// template's directories are all owner-writable, so the cause is on the
// device's data. These helpers report each level's mode and owner (via raw
// stat), re-add owner access where it is missing, then run the exact operation
// the downloader runs and say whether it now works. Every level of detail goes
// to the engine log; the callers get one honest verdict.

import Foundation
import Darwin

enum PrefixHealth {

    struct Level: CustomStringConvertible {
        let path: String
        let exists: Bool
        let isDirectory: Bool
        let ownerWritable: Bool
        let mode: String
        let uid: uid_t

        var description: String {
            "\(exists ? (isDirectory ? "dir" : "file") : "missing") mode=\(mode) uid=\(uid) \(ownerWritable ? "owner-w" : "OWNER-NOT-WRITABLE") \(path)"
        }
    }

    /// Documents → … → steamapps → common, outermost first.
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

    /// Report, repair what exists, probe the exact download step, log it all.
    /// Returns a one-line verdict for the UI.
    static func checkAndRepair(steamApps: URL) -> String {
        var lines: [String] = ["checking \(steamApps.path)"]
        let before = levels(steamApps: steamApps)
        for level in before { lines.append(level.description) }

        var repaired = 0
        for level in before where level.exists && (!level.ownerWritable || !level.isDirectory) {
            addOwnerAccess(URL(fileURLWithPath: level.path))
            repaired += 1
        }
        if repaired > 0 {
            lines.append("re-added owner access on \(repaired) level(s)")
            for level in levels(steamApps: steamApps) { lines.append("after: \(level.description)") }
        }

        var ok = true
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: steamApps, withIntermediateDirectories: true)
            let common = steamApps.appendingPathComponent("common", isDirectory: true)
            try fm.createDirectory(at: common, withIntermediateDirectories: true)
            let probe = common.appendingPathComponent(".windoz-write-probe")
            try Data([0x57]).write(to: probe)
            try? fm.removeItem(at: probe)
            lines.append("probe write to common: OK")
        } catch {
            ok = false
            lines.append("probe failed: \(error.localizedDescription)")
            for level in levels(steamApps: steamApps) { lines.append("after: \(level.description)") }
        }

        for line in lines { EngineLogStream.shared.append("[prefix-health] \(line)", level: ok ? .info : .warning) }
        return ok
            ? "Windows-prefix write path: OK — steamapps/common is writable."
            : "Windows-prefix write path: FAILED — the Log has the exact level and mode."
    }

    // MARK: - low level

    private static func inspect(_ url: URL) -> Level {
        var st = stat()
        let ok = url.withUnsafeFileSystemRepresentation { stat($0, &st) == 0 }
        let isDir = ok && (st.st_mode & S_IFMT) == S_IFDIR
        return Level(path: url.path,
                     exists: ok,
                     isDirectory: isDir,
                     ownerWritable: ok && (st.st_mode & 0o200) != 0,
                     mode: ok ? String(format: "%o", st.st_mode & 0o7777) : "----",
                     uid: ok ? st.st_uid : 0)
    }

    private static func addOwnerAccess(_ url: URL) {
        var st = stat()
        guard url.withUnsafeFileSystemRepresentation({ stat($0, &st) == 0 }) else { return }
        let wanted = (st.st_mode & 0o7777) | 0o700
        _ = url.withUnsafeFileSystemRepresentation { chmod($0, wanted) }
    }
}
