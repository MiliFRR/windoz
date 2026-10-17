// SPDX-License-Identifier: GPL-3.0-or-later
// Windoz — where the Steam library lives, decided by test, not by faith.
//
// Device test, 2026-10-17: the shipped location
// (`windoz-prefix/drive_c/Program Files (x86)/Steam/steamapps`) refused every
// creation — Foundation 513 ("You don't have permission to save the file
// “steamapps” in the folder “Steam”") — while every level of the path
// reported `mode=755 uid=501 owner-w`. Instead of leaving installs dead at
// that spot, the location is negotiated before a download: each candidate is
// tested with the exact operations an install runs (create `steamapps/common`,
// write and delete a file), through Foundation *and* through the C library,
// and the first one that passes is remembered in
// `windoz-steam-library-location.txt`. In-prefix choices are still `C:\` to
// Wine; the last fallback sits outside the prefix (Wine reaches it as `Z:`).

import Foundation

enum SteamLibraryLocator {

    static let ruleFileName = "windoz-steam-library-location.txt"

    static var ruleURL: URL { AppContainer.documents.appendingPathComponent(ruleFileName) }

    /// Steam's own client layout (`C:\Program Files (x86)\Steam\steamapps`).
    static var preferredRelative: String { "drive_c/\(SteamInstallPaths.libraryRelative)" }

    /// Tried in order after the preferred path refuses: two more places Wine
    /// sees as `C:\`, then one outside the prefix.
    static let fallbackRelatives = [
        "drive_c/SteamLibrary/steamapps",
        "drive_c/steamapps",
        "windoz-game-library/steamapps",
    ]

    static var allRelatives: [String] { [preferredRelative] + fallbackRelatives }

    static func url(forRelative relative: String) -> URL {
        AppContainer.documents.appendingPathComponent(relative, isDirectory: true)
    }

    /// The location reads use now: a remembered one when there is one (it was
    /// tested on this device), otherwise the preferred one.
    static func resolved() -> URL {
        if let remembered, allRelatives.contains(remembered) { return url(forRelative: remembered) }
        return url(forRelative: preferredRelative)
    }

    /// The location remembered in `windoz-steam-library-location.txt`.
    static var remembered: String? {
        guard let text = try? String(contentsOf: ruleURL, encoding: .utf8) else { return nil }
        let line = text.split(separator: "\n").first
            .map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        return line.isEmpty ? nil : line
    }

    static func remember(_ relative: String) {
        let result = ContainerFS.writeFile(ruleURL.path, Data("\(relative)\n".utf8))
        if !result.ok {
            EngineLogStream.shared.append("[steam-library] could not remember the location: \(result.detail)", level: .warning)
        }
    }

    // MARK: - Negotiation

    struct Choice {
        var relative: String
        var url: URL
        var changed: Bool
        var foundationOK: Bool
        var rawOK: Bool
        var lines: [String]
    }

    /// Make sure a writable library exists before a download starts. Never
    /// throws: when every candidate refuses, the resolved location is returned
    /// anyway and the log (and the downloader's deep check) carries the why.
    static func prepareForDownload() -> Choice {
        let before = remembered ?? preferredRelative
        var lines: [String] = []
        var order: [String] = []
        for relative in ([remembered].compactMap { $0 } + allRelatives) where !order.contains(relative) {
            order.append(relative)
        }
        var backup: (relative: String, foundationOK: Bool, rawOK: Bool)?
        for relative in order {
            guard let result = test(relative, lines: &lines) else { continue }
            if result.foundationOK && result.rawOK {
                return chosen(relative, before: before, result: result, lines: &lines)
            }
            if backup == nil {
                backup = (relative, result.foundationOK, result.rawOK)
                lines.append("\(relative): only one route works (Foundation \(result.foundationOK ? "ok" : "refused"), C library \(result.rawOK ? "ok" : "refused")) — kept as fallback")
            }
        }
        if let backup {
            return chosen(backup.relative, before: before, result: (backup.foundationOK, backup.rawOK), lines: &lines)
        }
        lines.append("no location passed the write test (see [prefix-health] for the per-level report)")
        log(lines, level: .error)
        BootTrace.mark("[steam-library] no writable location found")
        return Choice(relative: before, url: url(forRelative: before), changed: false,
                      foundationOK: false, rawOK: false, lines: lines)
    }

    private static func chosen(_ relative: String, before: String, result: (foundationOK: Bool, rawOK: Bool), lines: inout [String]) -> Choice {
        remember(relative)
        if relative != before { lines.append("using \(relative) instead of \(before)") }
        let level: LogLine.Level = (relative == before && result.foundationOK) ? .info : .warning
        log(lines, level: level)
        BootTrace.mark("[steam-library] \(relative) foundation=\(result.foundationOK ? 1 : 0) raw=\(result.rawOK ? 1 : 0)")
        return Choice(relative: relative, url: url(forRelative: relative), changed: relative != before,
                      foundationOK: result.foundationOK, rawOK: result.rawOK, lines: lines)
    }

    /// Test one candidate with the operations an install runs: create
    /// `steamapps/common`, write a probe file into it, delete the probe — once
    /// through Foundation, once through the C library. Returns nil when both
    /// routes refuse.
    private static func test(_ relative: String, lines: inout [String]) -> (foundationOK: Bool, rawOK: Bool)? {
        let url = url(forRelative: relative)
        let common = url.appendingPathComponent("common", isDirectory: true)
        lines.append("trying \(relative)")

        // Foundation — the route DepotDownloader's createDirectory uses.
        var foundationOK = false
        do {
            try FileManager.default.createDirectory(at: common, withIntermediateDirectories: true)
            let probe = common.appendingPathComponent(".windoz-locator-probe")
            do {
                try Data([0x57]).write(to: probe)
                do {
                    try FileManager.default.removeItem(at: probe)
                    foundationOK = true
                    lines.append("  Foundation: create + write + delete ok")
                } catch {
                    lines.append("  Foundation delete refused: \(describe(error))")
                }
            } catch {
                lines.append("  Foundation write refused: \(describe(error))")
            }
        } catch {
            lines.append("  Foundation mkdir refused: \(describe(error))")
        }

        // The C library — `mkdir -p`, then a real create + write + delete.
        var rawOK = false
        let dirs = ContainerFS.mkdirs(common.path)
        if dirs.ok {
            let probe = common.appendingPathComponent(".windoz-locator-probe-raw")
            let created = ContainerFS.writeFile(probe.path, Data([0x57]))
            if created.ok {
                let removed = ContainerFS.unlink(probe.path)
                rawOK = removed.ok
                lines.append(rawOK
                    ? "  C library: create + write + delete ok"
                    : "  C library delete refused: \(removed.detail)")
            } else {
                lines.append("  C library create refused: \(created.detail)")
            }
        } else {
            lines.append(contentsOf: dirs.lines)
        }

        if !foundationOK && !rawOK { return nil }
        return (foundationOK, rawOK)
    }

    private static func describe(_ error: Error) -> String {
        let raw = error as NSError
        return "\(raw.domain) \(raw.code) — \(raw.localizedDescription)"
    }

    private static func log(_ lines: [String], level: LogLine.Level) {
        for line in lines {
            EngineLogStream.shared.append("[steam-library] \(line)", level: level)
        }
    }
}
