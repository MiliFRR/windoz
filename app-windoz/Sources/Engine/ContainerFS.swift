// SPDX-License-Identifier: GPL-3.0-or-later
// Windoz — the C-library route to the container's filesystem.
//
// Device test, 2026-10-17: Foundation answered 513 ("You don't have
// permission to save the file … in the folder …") while creating a folder
// inside the prefix, even though every level above reported
// `mode=755 uid=501 owner-w` and the same paths stayed readable. Foundation
// and the C library take different routes through the container's file
// layer (hooks, protection classes, BSD flags), so every write Windoz
// depends on is attempted through both, and the raw errno is logged for
// whichever one is refused. These helpers are the C-library side; they
// never throw, so the caller can put the failure in front of the user.

import Foundation
import Darwin

enum ContainerFS {

    struct Result {
        let ok: Bool
        let errnoValue: Int32
        var detail: String {
            ok ? "ok" : "errno \(errnoValue) (\(String(cString: strerror(errnoValue))))"
        }
        static let fine = Result(ok: true, errnoValue: 0)
    }

    /// `mkdir -p`, one component at a time. The first refusal names itself.
    static func mkdirs(_ path: String) -> (ok: Bool, lines: [String]) {
        var lines: [String] = []
        var built = ""
        for component in path.split(separator: "/") {
            built += "/" + component
            let result = mkdir(built)
            if result.ok { continue }
            lines.append("raw mkdir \(built) failed: \(result.detail)")
            return (false, lines)
        }
        return (true, lines)
    }

    /// One `mkdir`; an existing entry (EEXIST) is not a failure.
    static func mkdir(_ path: String) -> Result {
        if Darwin.mkdir(path, 0o755) == 0 || errno == EEXIST { return .fine }
        return Result(ok: false, errnoValue: errno)
    }

    /// Create (or truncate) a file and write every byte of `contents`.
    /// Parent folders must exist; run `mkdirs` first.
    static func writeFile(_ path: String, _ contents: Data) -> Result {
        let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard fd >= 0 else { return Result(ok: false, errnoValue: errno) }
        defer { close(fd) }
        var written = 0
        return contents.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return Result.fine }
            while written < raw.count {
                let n = Darwin.write(fd, base + written, raw.count - written)
                if n <= 0 { return Result(ok: false, errnoValue: errno) }
                written += n
            }
            return Result.fine
        }
    }

    /// Create an empty file (no content), without truncating an existing one.
    static func createEmptyFile(_ path: String) -> Result {
        let fd = open(path, O_WRONLY | O_CREAT, 0o644)
        guard fd >= 0 else { return Result(ok: false, errnoValue: errno) }
        close(fd)
        return .fine
    }

    /// Delete a file. A name that is already gone counts as success.
    static func unlink(_ path: String) -> Result {
        if Darwin.unlink(path) == 0 { return .fine }
        return errno == ENOENT ? .fine : Result(ok: false, errnoValue: errno)
    }

    /// Remove an empty directory.
    static func rmdir(_ path: String) -> Result {
        if Darwin.rmdir(path) == 0 { return .fine }
        return errno == ENOENT ? .fine : Result(ok: false, errnoValue: errno)
    }

    static func rename(_ from: String, to: String) -> Result {
        if Darwin.rename(from, to) == 0 { return .fine }
        return Result(ok: false, errnoValue: errno)
    }

    /// BSD flags (`st_flags`): `0x2` = UF_IMMUTABLE, `0x80000` = SF_IMMUTABLE.
    /// A nonzero value on a folder that still reports owner-writable is the
    /// classic "cannot create or delete inside" answer, so the probes print it.
    static func flags(_ path: String) -> UInt32? {
        var st = stat()
        guard path.withCString({ lstat($0, &st) }) == 0 else { return nil }
        return st.st_flags
    }

    /// Clear every BSD flag on `path`. Only called for entries at or below the
    /// app's own Documents folder. Clearing `UF_IMMUTABLE` needs only our own
    /// write permission on the entry's parent; clearing `SF_IMMUTABLE` needs
    /// root, and that refusal is reported, never hidden.
    static func clearFlags(_ path: String) -> Result {
        if Darwin.chflags(path, 0) == 0 { return .fine }
        return Result(ok: false, errnoValue: errno)
    }

    /// The entries directly inside `path`, through `readdir` (the C-library
    /// route). Bounded; each name carries its type and BSD flags.
    static func children(_ path: String, limit: Int = 40) -> (ok: Bool, errnoValue: Int32, entries: [(name: String, type: String, flags: UInt32)]) {
        guard let dir = opendir(path) else { return (false, errno, []) }
        defer { closedir(dir) }
        var out: [(String, String, UInt32)] = []
        while let entry = readdir(dir), out.count < limit {
            var name = ""
            withUnsafePointer(to: entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: 256) { name = String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            var st = stat()
            let known = (path + "/" + name).withCString({ lstat($0, &st) }) == 0
            let type: String
            if !known { type = "?" }
            else if (st.st_mode & S_IFMT) == S_IFDIR { type = "dir" }
            else if (st.st_mode & S_IFMT) == S_IFLNK { type = "link" }
            else { type = "file" }
            out.append((name, type, known ? st.st_flags : 0))
        }
        return (true, 0, out)
    }
}
