// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 125hz
//
// The pinned engine's configuration, and Windoz's own durable copy of the
// memory-tier choice.
//
// Device history (0.9.0): Documents is not writable in this installation, so
// every write of Documents/madeira.cfg failed and the engine never saw a
// swap-mb key — the log said "swap tier off" while the setting looked saved.
// The app now owns the setting in UserDefaults, writes a per-launch cfg under
// the writable storage root, and points MADEIRA_CFG_GAME at it. The engine
// scans that file after madeira.cfg, so its keys win even when Documents is
// read-only. A best-effort copy still goes to Documents/madeira.cfg for other
// tools and for installations where Documents is writable.

import Foundation

/// Swap-memory settings, read from and written through the app.
///
/// The engine's file-backed guest tier is armed by `wine_process_start` in
/// WineProcessBridge.m: it looks for `swap-mb`, and when the value is at least
/// 64 MB it recreates `NSTemporaryDirectory()/madeira-swap.bin` with
/// `NSFileProtectionNone` and exports `MADEIRA_SWAP_FILE` / `MADEIRA_SWAP_MB`
/// to the guest. Windoz additionally prepares the same file and environment
/// before the launch, so the tier still arms if the bridge misses the cfg.
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
        /// New installations default to broad: the engine's classic coverage
        /// backs only a narrow set of allocations, which is why a configured
        /// tier could look armed while doing very little.
        var coverage: Coverage = .broad

        var isOff: Bool { sizeMB <= 0 }

        /// The choices Madeira offers, in the same order and units.
        static let sizes = [0, 1024, 2048, 4096]

        static func title(for sizeMB: Int) -> String {
            sizeMB <= 0 ? "Off" : "\(sizeMB / 1024) GB"
        }
    }

    /// What a launch needs to arm the tier. `configURL` is the writable cfg
    /// passed as MADEIRA_CFG_GAME; `swapFileURL` is the pre-created backing
    /// file. Both are nil when the tier is off.
    struct PreparedLaunch {
        var swap: Swap
        var configURL: URL?
        var swapFileURL: URL?
    }

    /// The engine reads this path for the general config: `wine_process_start`
    /// resolves the docs folder through `NSDocumentDirectory`.
    static var fileURL: URL {
        AppContainer.documents.appendingPathComponent("madeira.cfg")
    }

    /// Windoz's per-launch config. It lives under the write-probed storage
    /// root (Library or tmp when Documents is refused), so it exists even in
    /// installations where Documents is read-only.
    static var launchConfigURL: URL {
        AppContainer.storageRoot.appendingPathComponent("windoz-engine.cfg")
    }

    private static let storedSizeKey = "windoz.swap.sizeMB"
    private static let storedCoverageKey = "windoz.swap.coverage"

    // MARK: - Reading

    /// The setting the user last saved in Windoz. On first use, migrate a
    /// value that already exists in Documents/madeira.cfg.
    static func readSwap() -> Swap {
        if let stored = storedSwap() { return stored }
        let migrated = readDocumentsSwap()
        if !migrated.isOff || FileManager.default.fileExists(atPath: fileURL.path) {
            persist(migrated)
        }
        return migrated
    }

    private static func storedSwap() -> Swap? {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: storedSizeKey) != nil else { return nil }
        let size = defaults.integer(forKey: storedSizeKey)
        let raw = defaults.string(forKey: storedCoverageKey) ?? Coverage.broad.rawValue
        return Swap(sizeMB: normalize(size), coverage: Coverage(rawValue: raw) ?? .broad)
    }

    private static func readDocumentsSwap() -> Swap {
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
        swap.sizeMB = normalize(swap.sizeMB)
        return swap
    }

    // MARK: - Writing

    /// Saves the setting where the app can always read it, writes the
    /// per-launch cfg the engine will actually scan, and mirrors it into
    /// Documents/madeira.cfg when that folder allows a write.
    ///
    /// Only a failure to write the per-launch cfg is thrown: that is the one
    /// file a launch depends on. A read-only Documents is reported, not fatal.
    static func writeSwap(_ swap: Swap) throws {
        let normalized = Swap(sizeMB: normalize(swap.sizeMB), coverage: swap.coverage)
        persist(normalized)

        if normalized.isOff {
            try? FileManager.default.removeItem(at: launchConfigURL)
        } else {
            try writeLaunchConfig(normalized)
        }

        var mirror = "Documents/madeira.cfg"
        do {
            try writeDocumentsConfig(normalized)
        } catch {
            mirror = "Documents/madeira.cfg is not writable (\(error.localizedDescription)); the launch cfg is authoritative"
            EngineLogStream.shared.append(
                "[swap] could not mirror the setting to Documents/madeira.cfg: \(error.localizedDescription). The engine reads \(launchConfigURL.path) instead.",
                level: .warning)
        }

        EngineLogStream.shared.append(
            normalized.isOff
                ? "[swap] saved: tier off (\(mirror))."
                : "[swap] saved: \(normalized.sizeMB) MB, coverage \(normalized.coverage.rawValue); launch cfg \(launchConfigURL.path); \(mirror).",
            level: normalized.isOff ? .info : .success)
    }

    /// Prepares everything a launch needs. Called on the session queue before
    /// `wine_process_start`. Never throws: a pre-arm failure is logged and the
    /// bridge still gets the cfg and the normal environment.
    static func prepareLaunch() -> PreparedLaunch {
        let swap = readSwap()
        guard !swap.isOff else {
            try? FileManager.default.removeItem(at: launchConfigURL)
            return PreparedLaunch(swap: swap, configURL: nil, swapFileURL: nil)
        }

        var configURL: URL?
        do {
            configURL = try writeLaunchConfig(swap)
        } catch {
            EngineLogStream.shared.append(
                "[swap] the per-launch cfg could not be written at \(launchConfigURL.path): \(error.localizedDescription). The pre-armed environment is the fallback.",
                level: .warning)
        }

        let fileURL = prearmSwapFile(sizeMB: swap.sizeMB)
        return PreparedLaunch(swap: swap, configURL: configURL, swapFileURL: fileURL)
    }

    @discardableResult
    private static func writeLaunchConfig(_ swap: Swap) throws -> URL {
        var lines = [
            "# Windoz per-launch engine configuration.",
            "# Generated on every launch; edits here are replaced.",
            "swap-mb = \(swap.sizeMB)",
        ]
        if swap.coverage != .classic {
            lines.append("env.MADEIRA_SWAP_COVERAGE = \(swap.coverage.rawValue)")
        }
        // The block rule's default floor is 1 MB; naming it makes the log and
        // the bridge's own min-kb branch agree.
        if swap.coverage == .blocks {
            lines.append("swap-min-kb = 1024")
        }
        let text = lines.joined(separator: "\n") + "\n"
        do {
            try FileManager.default.createDirectory(at: launchConfigURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try Data(text.utf8).write(to: launchConfigURL, options: [.atomic])
        } catch {
            throw ConfigError.refused(error.localizedDescription)
        }
        return launchConfigURL
    }

    /// The Documents copy preserves every key Windoz does not own.
    private static func writeDocumentsConfig(_ swap: Swap) throws {
        let existing = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
        var lines = existing.split(whereSeparator: \.isNewline).map { line -> String in
            var line = String(line)
            if line.hasSuffix("\r") { line.removeLast() }
            return line
        }

        let managed: Set<String> = ["swap-mb", "env.madeira_swap_coverage", "swap-min-kb"]
        lines = lines.filter { line in
            guard let (key, _) = keyValue(Substring(line)) else { return true }
            return !managed.contains(key)
        }

        if !swap.isOff {
            lines.append("swap-mb = \(swap.sizeMB)")
            if swap.coverage != .classic {
                lines.append("env.MADEIRA_SWAP_COVERAGE = \(swap.coverage.rawValue)")
            }
            if swap.coverage == .blocks {
                lines.append("swap-min-kb = 1024")
            }
        }

        // A file with no keys left is not written at all: an empty cfg would
        // still switch the engine from legacy per-key files to cfg parsing.
        let meaningful = lines.contains { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return !trimmed.isEmpty && !trimmed.hasPrefix("#")
        }
        if !meaningful {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                try FileManager.default.removeItem(at: fileURL)
            }
            return
        }

        let text = lines.joined(separator: "\n") + "\n"
        try Data(text.utf8).write(to: fileURL, options: [.atomic])
    }

    /// Creates the sparse backing file with no file protection, matching what
    /// the bridge creates. If the bridge later finds `swap-mb` itself it
    /// removes and recreates this same path — harmless. If it misses the cfg,
    /// virtual_ios.c can still open this file (it does not pass O_CREAT).
    private static func prearmSwapFile(sizeMB: Int) -> URL? {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("madeira-swap.bin")
        let manager = FileManager.default
        do {
            if !manager.fileExists(atPath: url.path) {
                manager.createFile(atPath: url.path, contents: nil,
                                   attributes: [.protectionKey: FileProtectionType.none])
            }
            try manager.setAttributes([.protectionKey: FileProtectionType.none],
                                      ofItemAtPath: url.path)
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: UInt64(max(sizeMB, 64)) << 20)
            try handle.close()
            return url
        } catch {
            EngineLogStream.shared.append(
                "[swap] could not pre-create \(url.path): \(error.localizedDescription). The bridge can still create it when its cfg branch runs.",
                level: .warning)
            return nil
        }
    }

    private static func persist(_ swap: Swap) {
        UserDefaults.standard.set(swap.sizeMB, forKey: storedSizeKey)
        UserDefaults.standard.set(swap.coverage.rawValue, forKey: storedCoverageKey)
    }

    private static func normalize(_ sizeMB: Int) -> Int {
        sizeMB >= 64 ? sizeMB : 0
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

        var errorDescription: String? {
            switch self {
            case .refused(let why):
                return "Windoz could not save its per-launch engine configuration (\(why)). The swap setting cannot reach the engine."
            }
        }
    }
}
