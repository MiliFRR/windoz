// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 125hz
//
// Documents/madeira.cfg — the one configuration file the pinned engine reads.
// The app owns only the keys it writes; every other line is preserved so a
// setting never erases the user's (or another build's) configuration.

import Foundation

/// Swap-memory settings, read from and written to `Documents/madeira.cfg`.
///
/// The engine's file-backed guest tier is armed by `wine_process_start` in
/// WineProcessBridge.m: it looks for `swap-mb`, and when the value is at least
/// 64 MB it recreates `NSTemporaryDirectory()/madeira-swap.bin` with
/// `NSFileProtectionNone` and exports `MADEIRA_SWAP_FILE` / `MADEIRA_SWAP_MB`
/// to the guest. Windoz does not allocate or map the tier itself — it only
/// writes the same keys Madeira's Memory & sync page writes.
enum MadeiraConfig {

    /// `env.MADEIRA_SWAP_COVERAGE` — which allocations the tier backs. The
    /// engine's own default is classic; an absent line means classic.
    enum Coverage: String, CaseIterable, Identifiable, Codable {
        case classic
        case blocks
        case wide
        case broad

        var id: String { rawValue }

        var title: String {
            switch self {
            case .classic: return "Large allocations (default)"
            case .blocks: return "1 MB and larger"
            case .wide: return "Overflow allocations"
            case .broad: return "Whole reservations"
            }
        }

        var detail: String {
            switch self {
            case .classic: return "The tier backs allocation requests above the engine's threshold."
            case .blocks: return "Every allocation of 1 MB or more may draw on the tier."
            case .wide: return "Includes overflow allocations, covering more of a large title's working set."
            case .broad: return "Whole address-space reservations draw on the tier. The most coverage, with the most file traffic."
            }
        }
    }

    struct Swap: Equatable {
        var sizeMB: Int = 0
        var coverage: Coverage = .classic

        var isOff: Bool { sizeMB <= 0 }

        /// The choices Madeira offers, in the same order and units.
        static let sizes = [0, 1024, 2048, 4096]

        static func title(for sizeMB: Int) -> String {
            sizeMB <= 0 ? "Off" : "\(sizeMB / 1024) GB"
        }
    }

    /// The engine reads this exact path: `wine_process_start` resolves the
    /// docs folder through `NSDocumentDirectory`, which is this URL inside the
    /// app container.
    static var fileURL: URL {
        AppContainer.documents.appendingPathComponent("madeira.cfg")
    }

    // MARK: - Reading

    static func readSwap() -> Swap {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return Swap() }
        var swap = Swap()
        for line in text.split(whereSeparator: \.isNewline) {
            guard let (key, value) = keyValue(line) else { continue }
            switch key {
            case "swap-mb":
                swap.sizeMB = Int(value) ?? 0
            case "env.madeira_swap_coverage":
                if let coverage = Coverage(rawValue: value.lowercased()) { swap.coverage = coverage }
            default:
                break
            }
        }
        // The bridge ignores anything below 64 MB; show that as off rather
        // than a size the engine would silently discard.
        if swap.sizeMB < 64 { swap.sizeMB = 0 }
        return swap
    }

    // MARK: - Writing

    /// Replaces only `swap-mb` and `env.MADEIRA_SWAP_COVERAGE`; comments and
    /// every other key stay byte-for-byte in place. A swap size below 64 MB is
    /// written as off, because the bridge will not arm it.
    static func writeSwap(_ swap: Swap) throws {
        let existing = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
        var lines = existing.split(whereSeparator: \.isNewline).map { line -> String in
            var line = String(line)
            if line.hasSuffix("\r") { line.removeLast() }
            return line
        }

        let managed: Set<String> = ["swap-mb", "env.madeira_swap_coverage"]
        lines = lines.filter { line in
            guard let (key, _) = keyValue(Substring(line)) else { return true }
            return !managed.contains(key)
        }

        let size = swap.sizeMB >= 64 ? swap.sizeMB : 0
        if size > 0 {
            lines.append("swap-mb = \(size)")
            if swap.coverage != .classic {
                lines.append("env.MADEIRA_SWAP_COVERAGE = \(swap.coverage.rawValue)")
            }
        }

        // A file with no keys left is not written at all: an empty cfg would
        // still switch the engine from legacy per-key files to cfg parsing.
        let meaningful = lines.contains { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return !trimmed.isEmpty && !trimmed.hasPrefix("#")
        }
        if !meaningful {
            try? FileManager.default.removeItem(at: fileURL)
            return
        }

        let text = lines.joined(separator: "\n") + "\n"
        do {
            try Data(text.utf8).write(to: fileURL, options: [.atomic])
        } catch {
            throw ConfigError.refused(error.localizedDescription)
        }
        // Verify what the bridge will read, not what we meant to write.
        let written = readSwap()
        let expected = Swap(sizeMB: size, coverage: swap.coverage)
        guard written == expected else {
            throw ConfigError.verifyFailed
        }
        EngineLogStream.shared.append(
            size > 0
                ? "[swap] madeira.cfg: swap-mb=\(size), coverage=\(swap.coverage.rawValue)"
                : "[swap] madeira.cfg: swap tier off")
    }

    // MARK: - Parsing

    private static func keyValue(_ line: Substring) -> (key: String, value: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), let equals = trimmed.firstIndex(of: "=") else {
            return nil
        }
        let key = trimmed[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
        let value = trimmed[trimmed.index(after: equals)...].trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return nil }
        return (key, value)
    }

    private static func keyValue(_ line: String) -> (key: String, value: String)? {
        keyValue(Substring(line))
    }

    enum ConfigError: LocalizedError {
        case refused(String)
        case verifyFailed

        var errorDescription: String? {
            switch self {
            case .refused(let why):
                return "Windoz could not save Documents/madeira.cfg (\(why)). The engine reads the swap tier from that file, so the setting will not take effect."
            case .verifyFailed:
                return "Documents/madeira.cfg did not read back the saved value, so the swap setting was not applied."
            }
        }
    }
}
