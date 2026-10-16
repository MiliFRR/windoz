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
final class EngineLogStream: ObservableObject {
    static let shared = EngineLogStream()

    @Published private(set) var lines: [LogLine] = []

    private let cap = 2000
    private let queue = DispatchQueue(label: "windoz.log")

    func append(_ text: String, level: LogLine.Level = .info) {
        let line = LogLine(date: Date(), level: level, text: text)
        DispatchQueue.main.async {
            self.lines.append(line)
            if self.lines.count > self.cap {
                self.lines.removeFirst(self.lines.count - self.cap)
            }
        }
    }

    func clear() {
        DispatchQueue.main.async { self.lines.removeAll() }
    }

    /// A plain-text export for the "share log" action.
    func exportText() -> String {
        lines.map { line in
            "[\(Self.formatter.string(from: line.date))] [\(line.level.rawValue.uppercased())] \(line.text)"
        }.joined(separator: "\n")
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
