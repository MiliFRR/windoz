import Foundation

/// Owns the Wine prefix (the simulated `C:` drive) inside the app container.
/// Only the engine touches this; the UI asks `WindozEngine` for state.
struct PrefixManager {

    /// The prefix lives in Documents/windoz-prefix so the DLL farm, registry
    /// hives and installed games all sit next to the app's own data.
    let url: URL

    init(base: URL = URL.documentsDirectory) {
        self.url = base.appendingPathComponent("windoz-prefix", isDirectory: true)
    }

    var exists: Bool {
        FileManager.default.fileExists(atPath: url.appendingPathComponent("drive_c").path)
    }

    var windowsPath: URL { url.appendingPathComponent("drive_c/windows") }

    /// Create the prefix if it is new. Idempotent: the engine extracts its
    /// bundled template only the first time.
    func createIfNeeded() throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        madeira_seed_prefix_if_needed(url.path)
        guard exists else {
            throw EngineError.prefixCreateFailed("the bundled Windows environment template could not be extracted")
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
