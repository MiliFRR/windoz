// SPDX-License-Identifier: GPL-3.0-or-later
// Windoz — where the Steam library lives, decided by test, not by faith.
//
// Device test, 2026-10-17: the shipped location
// (`windoz-prefix/drive_c/Program Files (x86)/Steam/steamapps`) refused every
// creation — Foundation 513 ("You don't have permission to save the file
// “steamapps” in the folder “Steam”") — while every level of the path
// reported `mode=755 uid=501 owner-w`. The owner's next screenshots showed
// the refusals had widened: even the app's own `Documents` folder answered
// W-DENIED, while reading and network downloads kept working. Instead of
// leaving installs dead at that spot, the location is negotiated before a
// download: each candidate is tested with the exact operations an install
// runs (create `steamapps/common`, write and delete a file), through
// Foundation *and* through the C library, and the first one that passes is
// remembered in `windoz-steam-library-location.txt`. In-prefix choices are
// still `C:\` to Wine; the fallbacks leave the prefix — and the last two
// leave Documents itself (`Library`, `tmp`) for devices that refuse writes
// inside Documents. Build 0.3.3 appends one candidate inside every writable
// location the launch write-audit finds (app-group containers, temp dirs),
// so a device whose container folders all refuse can still land its games
// somewhere real. Rule values are home-relative paths or absolute paths
// (0.3.1 wrote Documents-relative values; those still read).

import Foundation

enum SteamLibraryLocator {

    static let ruleFileName = "windoz-steam-library-location.txt"

    /// The rule's home: the resolved storage root first, the legacy Documents
    /// path as a read fallback, and the Keychain as the durable copy (it is a
    /// small string, and the Keychain is the one store this device has proven
    /// it can write back when every file location refuses).
    private static let keychainAccount = "windoz.steam.library"

    static var ruleURL: URL { AppContainer.storageRoot.appendingPathComponent(ruleFileName) }
    static var legacyRuleURL: URL { AppContainer.documents.appendingPathComponent(ruleFileName) }

    /// Steam's own client layout (`C:\Program Files (x86)\Steam\steamapps`).
    static var preferredRelative: String { "Documents/drive_c/\(SteamInstallPaths.libraryRelative)" }

    /// Tried in order after the preferred path refuses: two more places Wine
    /// sees as `C:\`, one outside the prefix under Documents, and — because a
    /// device can refuse writes in Documents *itself* — one under `Library`
    /// and one under `tmp`. Everything is reachable in Wine later (the
    /// outside-prefix ones as `Z:`).
    static let fallbackRelatives = [
        "Documents/drive_c/SteamLibrary/steamapps",
        "Documents/drive_c/steamapps",
        "Documents/windoz-game-library/steamapps",
        "Library/windoz-game-library/steamapps",
        "tmp/windoz-game-library/steamapps",
    ]

    static var allRelatives: [String] { [preferredRelative] + fallbackRelatives }

    /// Relative paths are home-relative, so a candidate can leave Documents.
    static func url(forRelative relative: String) -> URL {
        AppContainer.home.appendingPathComponent(relative, isDirectory: true)
    }

    /// Every candidate: the name the rule file stores and its URL. The static
    /// list is home-relative; each writable root the boot audit found adds a
    /// candidate under its absolute path.
    static var allCandidates: [(name: String, url: URL)] {
        var out: [(name: String, url: URL)] = allRelatives.map { ($0, url(forRelative: $0)) }
        for root in AppContainer.discoveredRoots {
            let url = root.appendingPathComponent("windoz-game-library/steamapps", isDirectory: true)
            if !out.contains(where: { $0.url.standardizedFileURL.path == url.standardizedFileURL.path }) {
                out.append((url.path, url))
            }
        }
        return out
    }

    /// The location reads use now: a remembered one when there is one (it was
    /// tested on this device), otherwise the preferred one.
    static func resolved() -> URL {
        if let remembered, let candidate = candidate(named: remembered) { return candidate.url }
        return url(forRelative: preferredRelative)
    }

    /// The candidate a rule value names — current values are home-relative or
    /// absolute paths; build 0.3.1 wrote Documents-relative ones.
    private static func candidate(named raw: String) -> (name: String, url: URL)? {
        if let hit = allCandidates.first(where: { $0.name == raw }) { return hit }
        let legacy = "Documents/\(raw)"
        return allCandidates.first(where: { $0.name == legacy })
    }

    /// The location remembered in `windoz-steam-library-location.txt` (or in
    /// the Keychain, which outlives a container that refuses file writes).
    static var remembered: String? {
        if let stored = Keychain.getString(account: keychainAccount) {
            let line = stored.split(separator: "\n").first
                .map(String.init)?
                .trimmingCharacters(in: .whitespaces) ?? ""
            if !line.isEmpty { return line }
        }
        for url in [ruleURL, legacyRuleURL] {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let line = text.split(separator: "\n").first
                .map(String.init)?
                .trimmingCharacters(in: .whitespaces) ?? ""
            if !line.isEmpty { return line }
        }
        return nil
    }

    static func remember(_ relative: String) {
        let data = Data("\(relative)\n".utf8)
        Keychain.set(data, account: keychainAccount)
        var written = Set<String>()
        for url in [ruleURL, legacyRuleURL] where written.insert(url.standardizedFileURL.path).inserted {
            do {
                try data.write(to: url, options: .atomic)
            } catch {
                let result = ContainerFS.writeFile(url.path, data)
                if !result.ok {
                    EngineLogStream.shared.append(
                        "[steam-library] could not remember the location at \(url.path): \(result.detail)",
                        level: .warning)
                }
            }
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
        let rememberedCandidate = remembered.flatMap { candidate(named: $0) }
        let before = rememberedCandidate?.name ?? preferredRelative
        var lines: [String] = []
        var order: [(name: String, url: URL)] = allCandidates
        if let rememberedCandidate,
           let index = order.firstIndex(where: { $0.name == rememberedCandidate.name }) {
            order.remove(at: index)
            order.insert(rememberedCandidate, at: 0)
        }
        var backup: (name: String, foundationOK: Bool, rawOK: Bool)?
        for entry in order {
            guard let result = test(entry, lines: &lines) else { continue }
            if result.foundationOK && result.rawOK {
                return chosen(entry, before: before, result: result, lines: &lines)
            }
            if backup == nil {
                backup = (entry.name, result.foundationOK, result.rawOK)
                lines.append("\(entry.name): only one route works (Foundation \(result.foundationOK ? "ok" : "refused"), C library \(result.rawOK ? "ok" : "refused")) — kept as fallback")
            }
        }
        if let backup {
            if let entry = allCandidates.first(where: { $0.name == backup.name }) {
                return chosen(entry, before: before, result: (backup.foundationOK, backup.rawOK), lines: &lines)
            }
        }
        lines.append("no location passed the write test (see [prefix-health] for the per-level report)")
        log(lines, level: .error)
        BootTrace.mark("[steam-library] no writable location found")
        let fallbackURL = candidate(named: before)?.url ?? url(forRelative: preferredRelative)
        return Choice(relative: before, url: fallbackURL, changed: false,
                      foundationOK: false, rawOK: false, lines: lines)
    }

    private static func chosen(_ entry: (name: String, url: URL), before: String, result: (foundationOK: Bool, rawOK: Bool), lines: inout [String]) -> Choice {
        remember(entry.name)
        if entry.name != before { lines.append("using \(entry.name) instead of \(before)") }
        let level: LogLine.Level = (entry.name == before && result.foundationOK) ? .info : .warning
        log(lines, level: level)
        BootTrace.mark("[steam-library] \(entry.name) foundation=\(result.foundationOK ? 1 : 0) raw=\(result.rawOK ? 1 : 0)")
        return Choice(relative: entry.name, url: entry.url, changed: entry.name != before,
                      foundationOK: result.foundationOK, rawOK: result.rawOK, lines: lines)
    }

    /// Test one candidate with the operations an install runs: create
    /// `steamapps/common`, write a probe file into it, delete the probe — once
    /// through Foundation, once through the C library. Returns nil when both
    /// routes refuse.
    private static func test(_ entry: (name: String, url: URL), lines: inout [String]) -> (foundationOK: Bool, rawOK: Bool)? {
        let url = entry.url
        let common = url.appendingPathComponent("common", isDirectory: true)
        lines.append("trying \(entry.name)")

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
