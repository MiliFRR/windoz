import Foundation

/// Owns the Wine prefix (the simulated `C:` drive) inside the app container.
/// Only the engine touches this; the UI asks `WindozEngine` for state.
///
/// Location comes from `AppContainer.prefixRoot`, which is decided by real
/// write probes, never assumed: `Documents/windoz-prefix` while Documents
/// accepts writes (every build before 0.4.0), otherwise the first location
/// that passes — Library, tmp, or an audited root. When the location moves,
/// an existing environment is carried over as one unit (copy under a
/// temporary name, renamed into place only when complete); the old copy is
/// deliberately left untouched.
struct PrefixManager {

    let url: URL

    init(url: URL = AppContainer.prefixRoot) {
        self.url = url
    }

    /// Where every build before 0.4.0 kept the prefix.
    static var legacyURL: URL {
        AppContainer.documents.appendingPathComponent("windoz-prefix", isDirectory: true)
    }

    var exists: Bool {
        FileManager.default.fileExists(atPath: url.appendingPathComponent("drive_c").path)
    }

    var windowsPath: URL { url.appendingPathComponent("drive_c/windows") }

    /// The Steam client's own library folder inside this prefix, when the
    /// prefix sits in the active location (used by Doz Dock).
    var steamAppsURL: URL {
        url.appendingPathComponent("drive_c/\(SteamInstallPaths.libraryRelative)", isDirectory: true)
    }

    /// Create the prefix if it is new. Idempotent: the engine extracts its
    /// bundled template only the first time. Refusals carry the raw error and
    /// the C-library route's answer — no silent failure.
    func createIfNeeded() throws {
        if url.standardizedFileURL != Self.legacyURL.standardizedFileURL, !exists {
            migrateLegacyPrefixIfPresent()
        }
        var failure: String? = nil
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            do { try fm.createDirectory(at: url, withIntermediateDirectories: true) }
            catch { failure = "Foundation: \(error.localizedDescription)" }
        }
        if !fm.fileExists(atPath: url.path) {
            let made = ContainerFS.mkdirs(url.path)
            if made.ok { failure = nil }
            else {
                failure = (failure.map { $0 + "; " } ?? "") + "C library: " + made.lines.joined(separator: "; ")
            }
        }
        if let failure {
            throw EngineError.prefixCreateFailed("the folder refused creation at \(url.path) (\(failure))")
        }
        madeira_seed_prefix_if_needed(url.path)
        guard exists else {
            throw EngineError.prefixCreateFailed(
                "the bundled Windows environment template could not be extracted into \(url.path); the log's storage lines name what the device refused")
        }
    }

    /// Carry an existing environment from the legacy Documents location to the
    /// writable one the storage negotiation chose. One-time. The copy is made
    /// under a temporary name and renamed into place only when every file
    /// landed, so a half-copied prefix can never masquerade as a complete one.
    /// The old copy is left where it was: this device's Documents refused
    /// deletes and replaces, and a removal that half-succeeds would be worse
    /// than the bytes it would free.
    private func migrateLegacyPrefixIfPresent() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: Self.legacyURL.appendingPathComponent("drive_c").path) else { return }
        let parent = url.deletingLastPathComponent()
        try? fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let staging = parent.appendingPathComponent(url.lastPathComponent + ".migrating", isDirectory: true)
        let started = Date()
        EngineLogStream.shared.append(
            "[host] prefix: moving the Windows environment out of Documents (its folder refuses writes) to \(url.path) — one time")
        do {
            try? fm.removeItem(at: staging)
            try fm.copyItem(at: Self.legacyURL, to: staging)
            try? fm.removeItem(at: url)
            try fm.moveItem(at: staging, to: url)
            EngineLogStream.shared.append(
                "[host] prefix: moved in \(String(format: "%.1f", Date().timeIntervalSince(started))) s")
        } catch {
            try? fm.removeItem(at: staging)
            EngineLogStream.shared.append(
                "[host] prefix: the old environment could not be moved (\(error.localizedDescription)) — a fresh one is created; the old files were kept where they are",
                level: .warning)
        }
    }

    /// Delete the whole prefix. Callers must ensure no session is running.
    func delete() throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    /// Repair: throw the prefix away and extract a clean template. Game files
    /// installed outside the prefix are untouched.
    func repair() throws {
        try delete()
        try createIfNeeded()
    }

    /// Translate a host path inside `drive_c` into the guest `C:\` path the
    /// engine's launcher (`wine_process_start`) expects in `MADEIRA_EXE` and
    /// `MADEIRA_WORKDIR`. Returns nil when the path is outside the prefix; the
    /// caller then falls back to Wine's default `Z:` root mapping.
    func windowsPath(forHostPath host: String) -> String? {
        guard !host.isEmpty else { return nil }
        let driveC = url.appendingPathComponent("drive_c").standardizedFileURL.path
        let standardized = URL(fileURLWithPath: host).standardizedFileURL.path
        guard standardized.lowercased().hasPrefix(driveC.lowercased() + "/") else { return nil }
        let relative = String(standardized.dropFirst(driveC.count + 1))
        return "C:\\" + relative.replacingOccurrences(of: "/", with: "\\")
    }

    /// Where a guest `C:\` path maps, for showing paths in the UI.
    func hostPath(forWindowsPath path: String) -> URL {
        var p = path.replacingOccurrences(of: "\\", with: "/")
        if let range = p.range(of: ":/") {
            let drive = String(p[p.startIndex..<range.lowerBound]).lowercased()
            let rest = String(p[range.upperBound...])
            if drive == "c" {
                p = url.appendingPathComponent("drive_c").path + "/" + rest
            } else {
                p = url.appendingPathComponent("dosdevices").path + "/" + drive + ":/" + rest
            }
        }
        return URL(fileURLWithPath: p)
    }
}
