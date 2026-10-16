import Foundation

/// The kinds of anti-cheat Windoz can recognise from a game's own files.
/// Detection only — Windoz never attempts to bypass or defeat any of these.
enum AntiCheatKind: String, Codable, CaseIterable, Identifiable {
    case easyAntiCheat
    case battlEye
    case vanguard
    case punkBuster
    case ricochet
    case fairFight
    case xignCode
    case gameGuard
    case denuvo
    case unknown

    var id: String { rawValue }

    var title: String {
        switch self {
        case .easyAntiCheat: return "Easy Anti-Cheat"
        case .battlEye: return "BattlEye"
        case .vanguard: return "Riot Vanguard"
        case .punkBuster: return "PunkBuster"
        case .ricochet: return "Ricochet"
        case .fairFight: return "FairFight"
        case .xignCode: return "XignCode3"
        case .gameGuard: return "nProtect GameGuard"
        case .denuvo: return "Denuvo"
        case .unknown: return "Unknown anti-cheat"
        }
    }

    /// Does this product need kernel-level access? Those can never work in a
    /// usermode Wine process on a jailed iPhone.
    var isKernelLevel: Bool {
        switch self {
        case .vanguard, .easyAntiCheat, .battlEye, .xignCode, .gameGuard: return true
        default: return false
        }
    }
}

struct AntiCheatInfo: Codable, Hashable {
    var kind: AntiCheatKind
    /// The file(s) that identified it, relative to the install folder.
    var evidence: String
    var onlineRisk: OnlineRisk

    var shortExplanation: String {
        switch onlineRisk {
        case .offlineOnly:
            return "\(kind.title) was found. Single-player may work; its online modes are not supported and may detect the emulation and refuse to connect."
        case .unsupported:
            return "\(kind.title) was found. It requires kernel-level access that a jailed iOS app cannot provide, so the game will not run."
        case .unknown:
            return "\(kind.title) was found. Windoz does not know whether its online modes work here."
        }
    }
}

/// Scans an install folder for known anti-cheat and DRM artifacts. This is an
/// *awareness* layer: it tells the truth about what a game ships and what that
/// means for Windoz, and never tries to circumvent anything.
enum AntiCheatDetector {

    private struct Signature {
        let kind: AntiCheatKind
        let matches: [String]   // lower-case file/dir name fragments
    }

    // Ordered: the first, most specific hit wins.
    private static let signatures: [Signature] = [
        Signature(kind: .vanguard, matches: ["vgk.sys", "vgc.exe", "vgk.exe", "vgtray.exe"]),
        Signature(kind: .easyAntiCheat, matches: ["easyanticheat_eos.exe", "easyanticheat.exe", "easyanticheat_x64.dll", "easyanticheat.sys", "eaclauncher.exe", "eac_launcher"]),
        Signature(kind: .battlEye, matches: ["beservice_x64.exe", "beservice.exe", "beclient_x64.dll", "beclient.dll", "battleye"]),
        Signature(kind: .ricochet, matches: ["ricochet.exe", "ricochet.dll", "cod_ricochet"]),
        Signature(kind: .punkBuster, matches: ["pnkbstra.exe", "pnkbstrb.exe", "pbcl.dll", "pbsvc.exe", "punkbuster"]),
        Signature(kind: .fairFight, matches: ["fairfight", "ffservice"]),
        Signature(kind: .xignCode, matches: ["xigncode", "x3.xem", "xigncode3"]),
        Signature(kind: .gameGuard, matches: ["npggnt.des", "gamemon.des", "npgg.des", "gameguard"]),
        Signature(kind: .denuvo, matches: ["denuvo-anti-cheat.dll", "denuvo64.dll", "denuvo"]),
    ]

    /// Scan `folder` (depth-limited) for anti-cheat artifacts. Returns nil when
    /// nothing recognisable was found, so the game page can honestly say
    /// "no anti-cheat detected".
    static func detect(inFolder folder: String) -> AntiCheatInfo? {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: folder, isDirectory: &isDir), isDir.boolValue else { return nil }

        var found: AntiCheatInfo?
        var visited = 0
        let maxVisited = 4000

        func scan(_ path: String, depth: Int) {
            guard found == nil, depth <= 4, visited < maxVisited else { return }
            guard let entries = try? fm.contentsOfDirectory(atPath: path) else { return }
            for name in entries {
                visited += 1
                if visited > maxVisited || found != nil { return }
                let lower = name.lowercased()
                for sig in signatures where !sig.matches.isEmpty {
                    if sig.matches.contains(where: { lower.contains($0) }) {
                        found = classify(sig.kind, evidence: name)
                        return
                    }
                }
                let child = (path as NSString).appendingPathComponent(name)
                var childIsDir: ObjCBool = false
                if fm.fileExists(atPath: child, isDirectory: &childIsDir), childIsDir.boolValue {
                    // Don't descend into the store caches / prefix internals.
                    if lower == "windoz-prefix" || lower == "windows" || lower == "system32" { continue }
                    scan(child, depth: depth + 1)
                }
            }
        }

        scan(folder, depth: 0)
        return found
    }

    private static func classify(_ kind: AntiCheatKind, evidence: String) -> AntiCheatInfo {
        let risk: OnlineRisk
        switch kind {
        case .vanguard, .xignCode, .gameGuard:
            risk = .unsupported          // kernel-level, hard requirement
        case .easyAntiCheat, .battlEye, .punkBuster, .ricochet, .fairFight:
            risk = .offlineOnly          // may boot for single-player; online is not supported
        case .denuvo, .unknown:
            risk = .unknown
        }
        return AntiCheatInfo(kind: kind, evidence: evidence, onlineRisk: risk)
    }
}
