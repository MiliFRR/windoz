import Foundation

struct LogLine: Identifiable, Equatable {
    enum Level: String { case info, success, warning, error }

    let id = UUID()
    let date: Date
    let level: Level
    let text: String
}

/// A single in-memory log for the whole engine. The Wine/FEX/JIT layers push
/// through C callbacks; our own Swift code appends directly. Capped so a long
/// session cannot grow without bound.
///
/// Publishing is coalesced — at most ten times a second. A busy engine emits
/// log lines far faster than any view can render them, and pushing every line
/// straight into `@Published` made the UI (and the phone) work for nothing.
/// Lines buffer on whatever thread produced them and arrive in order.
final class EngineLogStream: ObservableObject {
    static let shared = EngineLogStream()

    @Published private(set) var lines: [LogLine] = []

    private let cap = 2000
    private let lock = NSLock()
    private var pending: [LogLine] = []
    private var flushScheduled = false
    private let flushInterval: TimeInterval = 0.1

    func append(_ text: String, level: LogLine.Level = .info) {
        let line = LogLine(date: Date(), level: level, text: text)
        lock.lock()
        pending.append(line)
        let schedule = !flushScheduled
        flushScheduled = true
        lock.unlock()
        // The on-disk sink sees every line as it arrives (the UI publish
        // above is coalesced; the file must not be).
        EngineLogFile.shared.append(line)
        if schedule {
            DispatchQueue.main.asyncAfter(deadline: .now() + flushInterval) { [weak self] in
                self?.flush()
            }
        }
    }

    func clear() {
        lock.lock()
        pending.removeAll()
        lock.unlock()
        DispatchQueue.main.async { self.lines.removeAll() }
    }

    /// The last `count` lines, including anything not yet published — the
    /// failure screens get the true tail of a launch even when the failure
    /// lands between two flushes. Main thread only (it reads `lines`).
    func recent(_ count: Int) -> [LogLine] {
        lock.lock()
        let tail = pending
        lock.unlock()
        return Array((lines + tail).suffix(count))
    }

    /// A plain-text export for the "share log" action.
    func exportText() -> String {
        lines.map { line in
            "[\(Self.formatter.string(from: line.date))] [\(line.level.rawValue.uppercased())] \(line.text)"
        }.joined(separator: "\n")
    }

    private func flush() {
        lock.lock()
        let batch = pending
        pending.removeAll()
        flushScheduled = false
        lock.unlock()

        lines.append(contentsOf: batch)
        if lines.count > cap { lines.removeFirst(lines.count - cap) }

        lock.lock()
        let more = !pending.isEmpty
        if more { flushScheduled = true }
        lock.unlock()
        if more {
            DispatchQueue.main.asyncAfter(deadline: .now() + flushInterval) { [weak self] in
                self?.flush()
            }
        }
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()
}

/// C trampolines. A non-capturing Swift function can be handed to the engine's
/// C log callbacks directly.
func windozEngineLogTrampoline(_ message: UnsafePointer<CChar>?) {
    guard let message else { return }
    EngineLogStream.shared.append(String(cString: message))
}
