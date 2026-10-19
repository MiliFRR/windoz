// SPDX-License-Identifier: GPL-3.0-or-later
// Windoz Converter Exception: see LICENSE-EXCEPTION.md

import Foundation

/// Stable identifiers for the launch pipeline's steps. The engine marks them
/// by id; the views read them by id. Strings, so they survive being shown in
/// a log or a shared report.
enum LaunchStepID {
    static let jit = "jit"
    static let prefix = "prefix"
    static let runtimes = "runtimes"
    static let exe = "exe"
    static let storage = "storage"
    static let mode = "mode"
    static let surface = "surface"
    static let service = "service"
    static let pool = "pool"
    static let guest = "guest"
    static let frame = "frame"
}

/// One step of the launch pipeline. Windoz builds the list before a launch,
/// marks each step as it runs, and keeps the result on screen — a launch is
/// never a black box that only says "starting".
struct LaunchStep: Identifiable, Equatable {
    enum State: Equatable {
        case pending
        case running
        case done
        case failed(String)
        case skipped(String)
    }

    let id: String
    let title: String
    var state: State = .pending
    /// The one line the step is doing right now ("Starting the CPU translator…").
    var detail = ""
    var startedAt: Date?
    var finishedAt: Date?
}

extension LaunchStep {
    /// The pipeline in the order `WindozEngine.launch` runs it.
    static func pipeline() -> [LaunchStep] {
        [
            LaunchStep(id: LaunchStepID.jit, title: "JIT is enabled"),
            LaunchStep(id: LaunchStepID.prefix, title: "Windows environment is ready"),
            LaunchStep(id: LaunchStepID.runtimes, title: "Windows runtimes checked"),
            LaunchStep(id: LaunchStepID.exe, title: "Game program found"),
            LaunchStep(id: LaunchStepID.storage, title: "Storage accepts writes"),
            LaunchStep(id: LaunchStepID.mode, title: "Launch mode prepared"),
            LaunchStep(id: LaunchStepID.surface, title: "Game screen is up"),
            LaunchStep(id: LaunchStepID.pool, title: "Executable memory is ready"),
            LaunchStep(id: LaunchStepID.service, title: "Windows service is running"),
            LaunchStep(id: LaunchStepID.guest, title: "Game process started"),
            LaunchStep(id: LaunchStepID.frame, title: "First frame presented"),
        ]
    }
}

/// The last launch that failed, kept for the game page's failure card: what
/// went wrong, which step stopped, one suggested repair.
struct LaunchFailure: Equatable {
    var gameID: UUID
    var gameTitle: String
    var message: String
    var hint: String?
    var failedStep: String?
    var at: Date = Date()
}

/// The text a "share this failure" action sends: the story, the step list and
/// the tail of the engine log, so a report needs no screenshots. Redaction is
/// the log's own — nothing here adds or removes secrets.
enum LaunchReport {
    static func text(failure: LaunchFailure, steps: [LaunchStep], log: [LogLine], limit: Int = 50) -> String {
        var lines: [String] = []
        lines.append("Windoz — launch failure report")
        lines.append("Game: \(failure.gameTitle)")
        lines.append("When: \(date.string(from: failure.at))")
        if let step = failure.failedStep {
            lines.append("Stopped at: \(step)")
        }
        lines.append("Error: \(failure.message)")
        if let hint = failure.hint {
            lines.append("Suggested fix: \(hint)")
        }
        lines.append("")
        lines.append("Launch steps:")
        for step in steps {
            let mark: String
            switch step.state {
            case .pending: mark = "—"
            case .running: mark = "…"
            case .done: mark = "ok"
            case .failed: mark = "FAILED"
            case .skipped: mark = "skipped"
            }
            var line = "  [\(mark)] \(step.title)"
            if !step.detail.isEmpty { line += " — \(step.detail)" }
            lines.append(line)
        }
        lines.append("")
        let tail = Array(log.suffix(limit))
        lines.append("Last \(tail.count) log lines:")
        for line in tail {
            lines.append("  \(time.string(from: line.date)) [\(line.level.rawValue)] \(line.text)")
        }
        return lines.joined(separator: "\n")
    }

    private static let date: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()
}
