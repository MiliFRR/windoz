// SPDX-License-Identifier: GPL-3.0-or-later
// Windoz — diagnostic-build launch forensics.
//
// The 2026-10-17 Steam+Epic build bounced to the home screen at launch inside
// LiveContainer, and LiveContainer gives no crash log for guests. This tracer
// appends one line per launch step to Documents/windoz-boot.log through raw
// POSIX calls, and BootGateView shows the tail on the next launch before any
// store or engine code can run. Temporary: removed once the crash is fixed.
//
// Crash-proof by construction: every call swallows failures, never throws,
// never force-unwraps, and the file handle is closed on each line so a crash
// can never lose more than the line that was being written.

import Foundation
import Darwin

enum BootTrace {

    static var url: URL { AppContainer.documents.appendingPathComponent("windoz-boot.log") }

    private static let lock = NSLock()
    private static var seen = Set<String>()
    private static var madeDocuments = false

    /// Append one line. Safe on any thread; failures are silent.
    static func mark(_ text: String) {
        let line = "[\(stamp())] \(text)\n"
        write(line)
    }

    /// Like `mark`, but writes once per process for a given key — for use
    /// inside `body` evaluations, which run many times.
    static func once(_ key: String) {
        lock.lock()
        let first = seen.insert(key).inserted
        lock.unlock()
        if first { mark(key) }
    }

    /// The last `maxLines` lines of the log, for the gate screen.
    static func tail(_ maxLines: Int = 200) -> String {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return "" }
        let usable = data.count > 256 << 10 ? data.suffix(256 << 10) : data
        let text = String(decoding: usable, as: UTF8.self)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        return lines.suffix(maxLines).joined(separator: "\n")
    }

    static func clear() {
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - low level

    private static func write(_ line: String) {
        guard let data = line.data(using: .utf8), !data.isEmpty else { return }
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var fd = open(url.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
            if fd < 0, !madeDocuments {
                // First launch of the build: Documents may not exist yet.
                madeDocuments = true
                try? FileManager.default.createDirectory(
                    at: AppContainer.documents, withIntermediateDirectories: true)
                fd = open(url.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
            }
            guard fd >= 0 else { return }
            _ = Darwin.write(fd, base, raw.count)
            _ = close(fd)
        }
    }

    private static func stamp() -> String {
        let now = Date().timeIntervalSince1970
        let whole = Int(now)
        let millis = Int((now - Double(whole)) * 1000)
        var t = time_t(whole)
        var tm = tm()
        localtime_r(&t, &tm)
        return String(format: "%02d:%02d:%02d.%03d", tm.tm_hour, tm.tm_min, tm.tm_sec, millis)
    }
}
