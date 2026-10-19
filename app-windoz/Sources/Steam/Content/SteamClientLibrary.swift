// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 125hz
//
// Games Valve's Steam client installed itself, made usable in Windoz.
//
// Windoz's own Steam downloads (Stores/SteamStore.swift) write the install
// record itself, so the library entry is created in the same breath. Games
// installed by the client — including games whose manifests are encrypted and
// cannot go through Windoz's downloader — only have the record on disk. This
// reads those records across every Steam library and materialises the same
// kind of library entry, defaulted to Doz Dock, which is how a client-installed
// game is meant to start.

import Foundation

enum SteamClientLibrary {

    struct ImportSummary {
        var total = 0
        var added = 0
        var updated = 0
        var missingExecutable = 0
        var failed = 0

        var message: String {
            guard total > 0 else {
                return "Steam's client has not installed any games in Windoz's libraries yet. Open Steam, install a game there, then come back."
            }
            var parts = ["Found \(total) installed Steam game\(total == 1 ? "" : "s")"]
            if added > 0 { parts.append("added \(added)") }
            if updated > 0 { parts.append("completed \(updated)") }
            if missingExecutable > 0 { parts.append("\(missingExecutable) without a program file found — set it in the game's settings") }
            if failed > 0 { parts.append("\(failed) could not be read") }
            return parts.joined(separator: " · ") + "."
        }
    }

    /// Adds every game Valve's client has installed in a Steam library to the
    /// Windoz library, or completes an entry that already exists (a missing
    /// executable, missing artwork). Existing settings are never reset.
    static func importInstalled(prefix: PrefixManager) async -> ImportSummary {
        var summary = ImportSummary()
        let games = DozDock.games(prefix: prefix).filter { $0.installed }
        summary.total = games.count
        guard !games.isEmpty else { return summary }

        let existing = await MainActor.run { GameLibrary.shared.games }
        var byAppID: [String: InstalledGame] = [:]
        for game in existing where game.storeID == StoreID.steam.rawValue {
            if let id = game.storeItemID { byAppID[id] = game }
        }

        for dockGame in games {
            let folder = prefix.url.appendingPathComponent("drive_c/\(dockGame.library)/common/\(dockGame.installDir)")
            var isFolder: ObjCBool = false
            guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isFolder), isFolder.boolValue else {
                summary.failed += 1
                continue
            }
            let appID = UInt32(exactly: dockGame.id) ?? 0
            let executable = SteamStore.scanForExecutable(in: folder)
            if executable == nil { summary.missingExecutable += 1 }

            if let previous = byAppID[String(dockGame.id)] {
                var completed = previous
                var changed = false
                if completed.executablePath.isEmpty, let executable {
                    completed.executablePath = executable
                    changed = true
                }
                if completed.workingDirectory.isEmpty {
                    completed.workingDirectory = folder.path
                    changed = true
                }
                if completed.coverArtPath == nil || completed.heroArtPath == nil {
                    let art = await SteamStore.fetchArtwork(appID: appID)
                    if let cover = art.cover?.path, completed.coverArtPath == nil {
                        completed.coverArtPath = cover
                        changed = true
                    }
                    if let hero = art.hero?.path, completed.heroArtPath == nil {
                        completed.heroArtPath = hero
                        changed = true
                    }
                }
                if changed {
                    let value = completed
                    await MainActor.run { GameLibrary.shared.update(value) }
                    summary.updated += 1
                }
            } else {
                var game = InstalledGame(
                    title: dockGame.name,
                    executablePath: executable ?? "",
                    workingDirectory: folder.path,
                    storeID: StoreID.steam.rawValue,
                    storeItemID: String(dockGame.id))
                game.antiCheat = AntiCheatDetector.detect(inFolder: folder.path)
                // Valve's client installed it; Valve's client starts it.
                game.settings.launchMode = .dock
                let art = await SteamStore.fetchArtwork(appID: appID)
                game.coverArtPath = art.cover?.path
                game.heroArtPath = art.hero?.path
                let value = game
                await MainActor.run { GameLibrary.shared.add(value) }
                summary.added += 1
            }
        }
        return summary
    }
}
