// SPDX-License-Identifier: GPL-3.0-or-later
// Windoz Converter Exception: see LICENSE-EXCEPTION.md

import Foundation

/// The one on-disk log (Phase 3): every line the in-memory stream holds is
/// appended to `windoz-logs/windoz.log` under the storage root, so a failure
/// can be shared after the in-memory cap has dropped it — and so the file
/// survives the app being killed mid-session.
///
/// The pinned engine additionally writes Wine's own debug output and the
/// guest's stdout/stderr to `madeira-log.txt` (its own hard-coded path); a
/// session's end appends the tail of that file here, so one log holds the
/// whole story.
final class EngineLogFile {
    static let shared = EngineLogFile()

    /// 5 MB per file, one previous generation kept. Enough for hours of a
    /// chatty session; small enough to share from a phone.
    private let limitBytes: UInt64 = 5 * 1024 * 1024
    private let queue = DispatchQueue(label: "windoz.log-file", qos: .utility)
    private var handle: FileHandle?

    private init() {}

    /// Where the on-disk log lives. A static path (not "wherever it opened")
    /// so Settings can show it before anything has been written.
    static var fileURL: URL {
        AppContainer.storageRoot
            .appendingPathComponent("windoz-logs", isDirectory: true)
            .appendingPathComponent("windoz.log")
    }

    /// The engine's own log file: the pinned Wine fork hard-codes
    /// `madeira-log.txt` in the app's Documents directory and dup2s the
    /// guest's stdout/stderr into it. Nil only if the system reports no
    /// Documents directory at all.
    static var engineLogURL: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("madeira-log.txt")
    }

    /// Open (or create) the log. Idempotent; failures leave the in-memory
    /// stream untouched and say why in it.
    func start() {
        queue.async {
            guard self.handle == nil else { return }
            let file = Self.fileURL
            do {
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
            } catch {
                self.noteUnavailable(error.localizedDescription)
                return
            }
            self.rotateIfNeeded(file)
            if !FileManager.default.fileExists(atPath: file.path) {
                FileManager.default.createFile(atPath: file.path, contents: nil)
            }
            guard let handle = try? FileHandle(forWritingTo: file) else {
                self.noteUnavailable("the file could not be opened for writing")
                return
            }
            handle.seekToEndOfFile()
            self.handle = handle
            let header = "\n==== Windoz \(AppContainer.displayVersion) — app run opened \(Self.stamp.string(from: Date())) ====\n"
            handle.write(Data(header.utf8))
        }
    }

    /// Called by `EngineLogStream` for every line, on whatever thread produced
    /// it. Writing is serialised on this class's queue; a missing handle is a
    /// silent no-op.
    func append(_ line: LogLine) {
        let text = "[\(Self.stamp.string(from: line.date))] [\(line.level.rawValue.uppercased())] \(line.text)\n"
        queue.async {
            guard let handle = self.handle else { return }
            handle.write(Data(text.utf8))
        }
    }

    /// Append the tail of the engine's own Wine/guest output, with a reason
    /// header. Called at session end (clean exit or failure) so the single
    /// Windoz log carries the guest's last words too.
    func appendEngineLogTail(reason: String, maxBytes: Int = 128 * 1024) {
        guard let url = Self.engineLogURL else { return }
        queue.async {
            guard self.handle != nil, let data = Self.tail(url, maxBytes: maxBytes), !data.isEmpty,
                  let text = String(data: data, encoding: .utf8) else { return }
            let header = "\n==== Wine and guest output (\(reason); tail of \(url.lastPathComponent)) ====\n"
            self.handle?.write(Data(header.utf8))
            self.handle?.write(Data(text.utf8))
            if !text.hasSuffix("\n") { self.handle?.write(Data("\n".utf8)) }
        }
    }

    private func noteUnavailable(_ why: String) {
        // Routes through the in-memory stream; the file sink is a no-op from
        // here (no handle), so this cannot loop.
        EngineLogStream.shared.append("[log] the on-disk log is unavailable: \(why). The in-memory log above still works.",
                                      level: .warning)
    }

    private func rotateIfNeeded(_ file: URL) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
              let size = attributes[.size] as? UInt64, size > limitBytes else { return }
        let previous = file.deletingPathExtension().appendingPathExtension("log.1")
        try? FileManager.default.removeItem(at: previous)
        try? FileManager.default.moveItem(at: file, to: previous)
    }

    private static func tail(_ url: URL, maxBytes: Int) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        try? handle.seek(toOffset: start)
        return try? handle.readToEnd()
    }

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()
}
