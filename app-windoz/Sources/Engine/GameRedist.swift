// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 125hz
// Windoz Converter Exception: see LICENSE-EXCEPTION.md
//
// Phase 5 — one-time installers a game ships in its own folder. Valve's clients
// run the "Run Process" entries of a game's installscript.vdf (typically
// redistributables under _CommonRedist) before the first start; Doz Dock starts
// games through Valve's client, which skips that here, so Windoz scans the
// game's folder and Steam's shared folder itself and lists what it finds on the
// game's page. Running one hands the vendor's own installer to a real Windows
// session — nothing is modified, nothing is redistributed.
//
// Whether an installer can run at all is read from its PE header, not guessed
// from its name: an x86 package cannot start in this 64-bit-only build and the
// row says so instead of failing later.
// Log tag: [redist].

import Foundation

struct GameRedistItem: Identifiable, Equatable {
    enum Machine: Equatable {
        case x64
        case x86
        case other(UInt16)
        case unknown

        var label: String {
            switch self {
            case .x64: return "64-bit"
            case .x86: return "32-bit"
            case .other(let value): return String(format: "machine 0x%04X", value)
            case .unknown: return "format unknown"
            }
        }

        var cannotRun: Bool { self == .x86 }
    }

    var name: String
    var hostPath: String
    var relativePath: String
    var machine: Machine
    var suggestedArguments: String?

    var id: String { hostPath }

    func ledgerKey(for game: InstalledGame) -> String {
        "redist:\(game.storeItemID ?? game.id.uuidString)/\(relativePath)"
    }
}

enum GameRedistScanner {
    /// The `_CommonRedist` folders around the game plus Steam's shared folder of
    /// the library the game lives in. Read-only, bounded (depth 4, a handful of
    /// ancestors), and only ever run when a screen asks for it.
    static func scan(game: InstalledGame, prefix: PrefixManager) -> [GameRedistItem] {
        let fm = FileManager.default
        var roots: [(url: URL, label: String)] = []

        let candidate = URL(fileURLWithPath: game.workingDirectory.isEmpty ? game.executablePath : game.workingDirectory)
        var ancestors: [URL] = []
        var here = candidate
        for _ in 0..<4 {
            ancestors.append(here)
            let parent = here.deletingLastPathComponent()
            if parent.path == here.path { break }
            here = parent
        }
        for dir in ancestors {
            let red = dir.appendingPathComponent("_CommonRedist")
            if fm.fileExists(atPath: red.path) { roots.append((red, "")) }
        }

        let shared = prefix.steamAppsURL.appendingPathComponent("common/Steamworks Shared/_CommonRedist")
        if fm.fileExists(atPath: shared.path) { roots.append((shared, "Steamworks Shared/")) }

        var items: [GameRedistItem] = []
        var seen = Set<String>()
        for root in roots {
            var found: [GameRedistItem] = []
            collect(in: root.url, root: root.url, depth: 0, into: &found)
            for var item in found {
                item.relativePath = root.label + item.relativePath
                if seen.insert(item.hostPath).inserted { items.append(item) }
            }
        }
        return items.sorted { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
    }

    private static func collect(in dir: URL, root: URL, depth: Int, into items: inout [GameRedistItem]) {
        guard depth <= 4 else { return }
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey],
                                                       options: [.skipsHiddenFiles]) else { return }
        for entry in entries {
            let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDirectory {
                collect(in: entry, root: root, depth: depth + 1, into: &items)
                continue
            }
            guard entry.pathExtension.lowercased() == "exe" else { continue }
            let relative = entry.path.replacingOccurrences(of: root.path + "/", with: "")
            items.append(GameRedistItem(name: entry.lastPathComponent,
                                        hostPath: entry.path,
                                        relativePath: relative,
                                        machine: machine(of: entry.path),
                                        suggestedArguments: suggestedArguments(for: entry.lastPathComponent)))
        }
    }

    /// Reads the PE header's machine field. Little-endian on purpose: an iOS app
    /// byte-order-independent read of the file's own layout.
    static func machine(of path: String) -> GameRedistItem.Machine {
        guard let handle = FileHandle(forReadingAtPath: path) else { return .unknown }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 0x40), head.count >= 0x40 else { return .unknown }
        let bytes = [UInt8](head)
        guard bytes[0] == 0x4D, bytes[1] == 0x5A else { return .unknown }
        let lfanew = UInt32(bytes[0x3C]) | (UInt32(bytes[0x3D]) << 8) | (UInt32(bytes[0x3E]) << 16) | (UInt32(bytes[0x3F]) << 24)
        guard lfanew > 0x40, lfanew < 0x0200_0000 else { return .unknown }
        guard (try? handle.seek(toOffset: UInt64(lfanew))) != nil else { return .unknown }
        guard let signature = try? handle.read(upToCount: 6), signature.count == 6 else { return .unknown }
        let sig = [UInt8](signature)
        guard sig[0] == 0x50, sig[1] == 0x45 else { return .unknown }
        let raw = UInt16(sig[4]) | (UInt16(sig[5]) << 8)
        switch raw {
        case 0x8664: return .x64
        case 0x014C: return .x86
        default: return .other(raw)
        }
    }

    /// Silent flags for the well-known families; anything else runs without
    /// arguments and the session's own output tells the story.
    static func suggestedArguments(for name: String) -> String? {
        let lower = name.lowercased()
        if lower.contains("vc_redist") { return "/install /quiet /norestart" }
        if lower.contains("vcredist") { return "/q /norestart" }
        if lower.contains("dxsetup") { return "/silent" }
        if lower.contains("dotnetfx") || lower.hasPrefix("ndp") || lower.contains("netfx") { return "/q /norestart" }
        if lower.contains("oalinst") { return "/s" }
        if lower.contains("xnafx") { return "/q /norestart" }
        return nil
    }
}
