// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 125hz
// Madeira Converter Exception: see LICENSE-EXCEPTION.md
//
// Doz Dock — Windoz's port of Madeira's Dock (work/madeira-pinned/app/Madeira/
// MadeiraDock.swift). Ported for Windoz with the Madeira authors' conversion
// exception; the app-side contract is kept exactly:
//
//  - the bundled dockhost.exe (briged into C:\windows\system32 by the engine)
//    loads Valve's genuine Windows Steam client in the session, signs in with
//    the owner's own refresh token and asks the client to start an installed
//    game with Valve's own LaunchApp. Valve's client performs the online
//    authentication and licence checks; the game and its DRM are untouched.
//    Nothing here circumvents DRM: Steam-DRM games run through Valve's own
//    client, exactly as on a PC.
//  - sign-in travels as a bounded one-use transfer file (header "MDOCK001"),
//    mode 0600, placed in Application Support when writable — anywhere on the
//    resolved storage root when this device's Library refuses writes — and
//    reaches the guest through Wine's \\?\unix namespace. No token, account
//    name or path is ever logged.
//  - the host writes a numeric report to C:\madeira-dock.txt
//    (`[steam-host] <round> <field>=<value>`); Windoz reads it after the
//    session and puts the honest reason in front of the user.
//  - offline sign-in is Valve's own offline mode, requested — never faked —
//    with MADEIRA_DOCK_OFFLINE=1 when the owner asks for it or the device has
//    no network path.
//
// The host only drives Steam client builds it has verified by SHA-256; an
// unrecognized build fails closed with a report code, and that is shown as is.

import Foundation
import Network

enum DozDock {

    /// `dockhost.exe` ships in the app bundle's arm64ec-windows folder (built
    /// by the pinned tree's build/madeira-dock/build.sh; the engine bridges
    /// every file of that folder into C:\windows\system32 at session start).
    static var bundled: Bool {
        if Bundle.main.url(forResource: "dockhost", withExtension: "exe",
                           subdirectory: "arm64ec-windows") != nil { return true }
        // LiveContainer can re-parent Bundle.main; check the common roots too.
        for root in [Bundle.main.bundleURL, Bundle.main.resourceURL].compactMap({ $0 }) {
            if FileManager.default.fileExists(
                atPath: root.appendingPathComponent("arm64ec-windows/dockhost.exe").path) {
                return true
            }
        }
        return false
    }

    static let executable = "C:\\windows\\system32\\dockhost.exe"

    /// A game Steam's client has installed in one of its C: libraries, read
    /// from `<library>/appmanifest_<appid>.acf`.
    struct Game: Identifiable, Equatable, Sendable {
        let id: Int                 // App ID
        let name: String
        let installDir: String      // one folder name under <library>/common
        /// The library folder, drive-relative (e.g.
        /// "Program Files (x86)/Steam/steamapps"). Steam titles can live in a
        /// second library on C:; the install path follows the record's own
        /// library instead of assuming the client's.
        let library: String
        let installed: Bool         // StateFlags has "fully installed"
        let customExecutables: Bool // the install record lists per-user executables (CheckGuid)

        /// The game's folder as Wine sees it.
        var windowsInstallPath: String {
            "C:\\" + library.replacingOccurrences(of: "/", with: "\\") + "\\common\\" + installDir
        }
    }

    // MARK: Installed games

    static func validAppID(_ value: Int) -> Bool { value > 0 && UInt64(value) < UInt64(UInt32.max) }

    /// One folder name: no separators, drive letters, parent references or control characters.
    static func validFolderName(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.count <= 240 && name != "." && name != ".." &&
            !name.contains("/") && !name.contains("\\") && !name.contains(":") && !name.contains("\"") &&
            !name.unicodeScalars.contains { $0.value < 32 } && !name.hasSuffix(" ") && !name.hasSuffix(".")
    }

    /// Every Steam library on C: the client knows: its own folder plus the
    /// ones its `libraryfolders.vdf` lists (ported from MadeiraDock). Valve's
    /// client writes that file when the user adds a library; the dock follows
    /// it instead of pretending every game lives in the client's own folder.
    static func libraries(prefix: PrefixManager) -> [String] {
        let clientLibrary = SteamInstallPaths.libraryRelative
        var libraries = [clientLibrary]
        let vdf = prefix.url.appendingPathComponent("drive_c/\(clientLibrary)/libraryfolders.vdf")
        if let data = try? Data(contentsOf: vdf), data.count <= 1 << 20,
           var parser = try? SteamKeyValues(data), let root = try? parser.read() {
            for (_, entry) in (root["libraryfolders"]?.fields ?? [:]).sorted(by: { $0.key < $1.key }) {
                guard let path = entry["path"]?.string?.replacingOccurrences(of: "\\\\", with: "\\"),
                      let relative = libraryRelative(path) else { continue }
                if !libraries.contains(where: { $0.caseInsensitiveCompare(relative) == .orderedSame }) {
                    libraries.append(relative)
                }
            }
        }
        return Array(libraries.prefix(16))
    }

    /// "C:\\Games\\SteamLibrary" -> "Games/SteamLibrary/steamapps" (C: only —
    /// the same restriction as the fork: the host is given a Windows path, and
    /// a library outside C: is not one the client and Wine agree on).
    static func libraryRelative(_ windowsPath: String) -> String? {
        let path = windowsPath.replacingOccurrences(of: "\\", with: "/")
        guard path.lowercased().hasPrefix("c:/") else { return nil }
        let parts = path.dropFirst(3).split(separator: "/").map(String.init)
        guard !parts.isEmpty, parts.count <= 16, parts.allSatisfy(validFolderName) else { return nil }
        return (parts + ["steamapps"]).joined(separator: "/")
    }

    /// The Dock game a Windoz library entry maps to, read from the install
    /// record in any of Steam's C: libraries inside the active prefix. Nil when
    /// no record names the app.
    static func game(for installed: InstalledGame, prefix: PrefixManager) -> Game? {
        guard let raw = installed.storeItemID, let appID = Int(raw), validAppID(appID) else { return nil }
        for library in libraries(prefix: prefix) {
            let record = prefix.url.appendingPathComponent("drive_c/\(library)/appmanifest_\(appID).acf")
            guard let data = try? Data(contentsOf: record) else { continue }
            if let game = game(manifest: data, library: library) { return game }
        }
        return nil
    }

    /// Every installed game across Steam's C: libraries (read-only). Records
    /// that only lend depots to another install ("Shared Only", e.g. a
    /// launcher's shared content) have nothing of their own to start and are
    /// left out — the same test as Madeira Dock's.
    static func games(prefix: PrefixManager) -> [Game] {
        let fm = FileManager.default
        var result: [Game] = []
        var lent: [Int: Set<String>] = [:], installed: [Int: Set<String>] = [:]
        for library in libraries(prefix: prefix) {
            let folder = prefix.url.appendingPathComponent("drive_c/\(library)", isDirectory: true)
            guard let names = try? fm.contentsOfDirectory(atPath: folder.path) else { continue }
            for file in names.sorted().prefix(2000) where file.hasPrefix("appmanifest_") && file.hasSuffix(".acf") {
                guard let data = try? Data(contentsOf: folder.appendingPathComponent(file)) else { continue }
                let held = depots(manifest: data)
                lent.merge(held.lent) { $0.union($1) }
                guard let game = game(manifest: data, library: library),
                      !result.contains(where: { $0.id == game.id }) else { continue }
                installed[game.id] = held.installed
                result.append(game)
            }
        }
        result.removeAll { game in
            guard let lenders = lent[game.id] else { return false }
            return installed[game.id, default: []].isSubset(of: lenders)
        }
        return result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// A record's depots: the ones it lends from each owner app (`SharedDepots`,
    /// depot -> owner) and the ones installed for the app itself.
    static func depots(manifest data: Data) -> (lent: [Int: Set<String>], installed: Set<String>) {
        guard data.count <= 1 << 20, var parser = try? SteamKeyValues(data), let root = try? parser.read(),
              let state = root["AppState"], let appID = state["appid"]?.string.flatMap({ Int($0) }) else { return ([:], []) }
        var lent: [Int: Set<String>] = [:]
        for (depot, owner) in (state["SharedDepots"]?.fields ?? [:]).prefix(64) {
            guard let ownerID = owner.string.flatMap({ Int($0) }), validAppID(ownerID), ownerID != appID else { continue }
            lent[ownerID, default: []].insert(depot)
        }
        return (lent, Set((state["InstalledDepots"]?.fields ?? [:]).keys.prefix(256)))
    }

    /// The game an app manifest describes, or nil when it is not one Dock can start.
    static func game(manifest data: Data, library: String = SteamInstallPaths.libraryRelative) -> Game? {
        guard data.count <= 1 << 20, var parser = try? SteamKeyValues(data), let root = try? parser.read(),
              let state = root["AppState"], let appID = state["appid"]?.string.flatMap({ Int($0) }), validAppID(appID),
              let folder = state["installdir"]?.string, validFolderName(folder) else { return nil }
        let flags = state["StateFlags"]?.string.flatMap { UInt32($0) } ?? 0
        let name = state["name"]?.string.map { String($0.prefix(200)) } ?? ""
        return Game(id: appID, name: name.isEmpty ? "App \(appID)" : name,
                    installDir: folder, library: library,
                    installed: flags & 4 != 0,
                    customExecutables: !(state["CheckGuid"]?.fields.isEmpty ?? true))
    }

    /// Everything a launch needs, checked before any sign-in is handed over.
    static func validate(_ game: Game, prefix: PrefixManager) throws {
        guard bundled else {
            throw EngineError.dockNotReady("the dock host was not built into this app (dockhost.exe is missing from the bundle). Use Direct instead.")
        }
        let drive = prefix.url.appendingPathComponent("drive_c")
        guard FileManager.default.fileExists(atPath: drive.appendingPathComponent(SteamClientRuntime.relativeRoot + "/steamclient64.dll").path) else {
            throw EngineError.dockNotReady("Valve's Steam client files are not in the Windows drive yet. In this game's settings, under “Steam launch”, download Steam's components (about 72 MB from Valve's own CDN), then start again.")
        }
        var isFolder: ObjCBool = false
        guard game.installed,
              FileManager.default.fileExists(atPath: drive.appendingPathComponent(game.library + "/common/" + game.installDir).path, isDirectory: &isFolder),
              isFolder.boolValue else {
            throw EngineError.dockNotReady("Steam does not list this game as fully installed inside the Windows drive (checked every library Steam's client lists). A copy that was downloaded when storage was refused may sit outside it — reinstall the game now that storage works, or use Direct.")
        }
    }

    // MARK: Sign-in transfer

    /// Tokens stay in the Keychain except for this bounded one-use transfer.
    /// The payload is not an ownership claim: Valve authenticates it in the
    /// guest, and the game only ever starts if Valve's client accepts it.
    static func envelope(account: String, token: String, steamID: UInt64, appID: Int) throws -> Data {
        let name = Array(account.utf8), secret = Array(token.utf8)
        guard (1...64).contains(name.count), (1...8192).contains(secret.count),
              name.allSatisfy({ (33...126).contains($0) }),
              secret.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || [45, 46, 95].contains($0) }),
              steamID >> 56 == 1, (steamID >> 52) & 15 == 1, (steamID >> 32) & 0xfffff == 1,
              steamID & 0xffffffff != 0, validAppID(appID) else {
            throw EngineError.dockNotReady("your Steam sign-in cannot be handed to Doz Dock. Sign in to Steam again in Windoz, then start the game.")
        }
        var data = Data("MDOCK001".utf8)
        func append(_ value: UInt64, bytes: Int) {
            for i in 0..<bytes { data.append(UInt8(truncatingIfNeeded: value >> (i * 8))) }
        }
        append(steamID, bytes: 8); append(UInt64(appID), bytes: 4)
        append(UInt64(name.count), bytes: 2); append(UInt64(secret.count), bytes: 2)
        data.append(contentsOf: name); data.append(contentsOf: secret)
        return data
    }

    /// The JWT subject selects the account; it is deliberately not treated as
    /// authenticated identity. Only Valve accepting the token can establish it.
    static func subject(_ token: String) throws -> UInt64 {
        guard token.utf8.count <= 8192 else {
            throw EngineError.dockNotReady("the Steam sign-in is too large to hand over. Sign in to Steam again in Windoz.")
        }
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else {
            throw EngineError.dockNotReady("the Steam sign-in needs renewal. Sign in to Steam again in Windoz.")
        }
        var encoded = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let data = Data(base64Encoded: encoded),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = json["sub"] as? String, let id = UInt64(text) else {
            throw EngineError.dockNotReady("the Steam sign-in needs renewal. Sign in to Steam again in Windoz.")
        }
        return id
    }

    /// The seeded prefix has C: but no guaranteed Z: mapping. Wine's Unix
    /// namespace reaches the protected native file without a drive mapping
    /// and without moving the transfer into the user-visible Documents folder.
    static func handoffGuestPath(_ url: URL, unixNamespace: Bool = true) -> String {
        (unixNamespace ? "\\\\?\\unix" : "Z:") + url.path.replacingOccurrences(of: "/", with: "\\")
    }

    /// Where the one-use transfer is written. Application Support first (the
    /// protected location Madeira Dock uses); this device's Library can refuse
    /// writes, so the resolved storage root is the fallback — same file, same
    /// mode, same one-use lifetime.
    private static var transferFolderCandidates: [URL] {
        var urls: [URL] = []
        if let support = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                      appropriateFor: nil, create: false) {
            urls.append(support.appendingPathComponent("windoz-dock", isDirectory: true))
        }
        urls.append(AppContainer.storageRoot.appendingPathComponent("windoz-dock", isDirectory: true))
        return urls
    }

    /// Removes an unconsumed transfer (session end, sign-out, app start).
    static func cleanup() {
        for folder in transferFolderCandidates {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent("launch.auth"))
        }
        unsetenv("MADEIRA_DOCK_AUTH_FILE")
        unsetenv("MADEIRA_DOCK_OFFLINE")
    }

    /// Writes the one-use transfer (mode 0600, created exclusively, excluded
    /// from backups) and puts only its guest path in the environment. No
    /// token, account name or path is logged.
    @discardableResult
    static func writeHandoff(account: String, token: String, appID: Int, prefix: PrefixManager) throws -> String {
        cleanup()
        // A stale report from a previous session must never be read as this
        // launch's outcome.
        try? FileManager.default.removeItem(at: reportURL(prefix: prefix))
        lastReport = [:]
        var lastError: String? = nil
        let fm = FileManager.default
        for candidate in transferFolderCandidates {
            var folder = candidate
            do {
                try fm.createDirectory(at: folder, withIntermediateDirectories: true,
                                       attributes: [.posixPermissions: 0o700])
                guard try folder.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
                    lastError = "the transfer folder is a link"; continue
                }
                var values = URLResourceValues(); values.isExcludedFromBackup = true
                try? folder.setResourceValues(values)
                let url = folder.appendingPathComponent("launch.auth")
                try? fm.removeItem(at: url)
                var data = try envelope(account: account, token: token, steamID: try subject(token), appID: appID)
                defer { data.resetBytes(in: data.startIndex..<data.endIndex) }
                let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
                guard descriptor >= 0 else { lastError = "create refused at \(folder.path)"; continue }
                let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
                do {
                    try file.write(contentsOf: data); try file.close()
                    let guest = handoffGuestPath(url)
                    setenv("MADEIRA_DOCK_AUTH_FILE", guest, 1)
                    EngineLogStream.shared.append("[dock-handoff] protected-file-ready=1 (\(folder.lastPathComponent))")
                    return guest
                } catch {
                    try? file.close(); try? fm.removeItem(at: url)
                    lastError = error.localizedDescription
                }
            } catch {
                lastError = error.localizedDescription
            }
        }
        throw EngineError.dockNotReady("Dock's private sign-in transfer could not be prepared (\(lastError ?? "no writable folder")).")
    }

    // MARK: Environment

    /// The host's environment for one launch (ported from MadeiraDock.configure).
    static func configure(_ game: Game) {
        for key in ["MADEIRA_STEAM_HOST_PROBE", "MADEIRA_STEAM_HOST_SESSION", "MADEIRA_STEAM_HOST_LOGIN", "MADEIRA_STEAM_HOST_LAUNCH"] {
            setenv(key, "1", 1)
        }
        setenv("MADEIRA_STEAM_HOST_APPID", String(game.id), 1)
        setenv("MADEIRA_STEAM_HOST_LAUNCH_OPTION", "0", 1)
        setenv("MADEIRA_STEAM_HOST_CLIENT_DIR", SteamClientRuntime.windowsRoot, 1)
        setenv("MADEIRA_STEAM_HOST_EXPECTED_INSTALL", game.windowsInstallPath, 1)
        setenv("MADEIRA_STEAM_HOST_LOG", "C:\\madeira-dock.txt", 1)
        // The install record lists per-user executables: Dock asks Valve's
        // client to prepare them before it launches.
        if game.customExecutables {
            setenv("MADEIRA_STEAM_HOST_CEG", "1", 1)
        } else {
            unsetenv("MADEIRA_STEAM_HOST_CEG")
        }
        // Never let a stale environment choose the PC cached-account test path.
        unsetenv("MADEIRA_STEAM_HOST_ACCOUNT"); unsetenv("MADEIRA_STEAM_HOST_STEAMID")
        EngineLogStream.shared.append("[dock] host environment armed: app=\(game.id), client=\(SteamClientRuntime.windowsRoot), install=\(game.windowsInstallPath), ceg=\(game.customExecutables), report=C:\\madeira-dock.txt.")
    }

    /// Opposite of `configure`: every dock variable is removed before any
    /// other launch, so a direct session can never inherit dock state.
    static func clearEnvironment() {
        for key in ["MADEIRA_DOCK_SESSION", "MADEIRA_DOCK_AUTH_FILE", "MADEIRA_DOCK_OFFLINE",
                    "MADEIRA_STEAM_HOST_PROBE", "MADEIRA_STEAM_HOST_SESSION", "MADEIRA_STEAM_HOST_LOGIN",
                    "MADEIRA_STEAM_HOST_LAUNCH", "MADEIRA_STEAM_HOST_APPID", "MADEIRA_STEAM_HOST_LAUNCH_OPTION",
                    "MADEIRA_STEAM_HOST_CLIENT_DIR", "MADEIRA_STEAM_HOST_EXPECTED_INSTALL",
                    "MADEIRA_STEAM_HOST_LOG", "MADEIRA_STEAM_HOST_CEG",
                    "MADEIRA_STEAM_HOST_ACCOUNT", "MADEIRA_STEAM_HOST_STEAMID"] {
            unsetenv(key)
        }
    }

    /// The dock session's guest arguments: Valve's client's host on its own
    /// virtual desktop. `MADEIRA_ARGS` is split at spaces and passed on as
    /// is, so no token is ever quoted here.
    static func launchArguments(width: Int, height: Int) -> String {
        "/desktop=madeira,\(width)x\(height) \(executable)"
    }

    // MARK: Offline (Valve's own offline mode)

    /// Valve's client can log an account on without a connection (desktop
    /// Steam's Offline Mode; madeira-dock docs/OFFLINE.md). The host asks the
    /// client for exactly that; Windoz decides nothing about ownership and
    /// stores no ticket. This enum only decides when to ask.
    enum Offline {
        private static let monitor = NWPathMonitor()
        private static var started = false

        /// Starts the path monitor at app start, so the path is current by
        /// the time anything is launched.
        static func begin() {
            guard !started else { return }
            started = true
            monitor.start(queue: DispatchQueue(label: "windoz.dock-offline.path"))
        }

        /// No usable network path right now. False until the monitor started.
        static var networkDown: Bool { started && monitor.currentPath.status != .satisfied }

        /// Sets or clears `MADEIRA_DOCK_OFFLINE` for the next launch. Returns
        /// the decision so the log can say whose choice it was.
        @discardableResult
        static func apply(requested: Bool) -> Bool {
            let offline = requested || networkDown
            if offline { setenv("MADEIRA_DOCK_OFFLINE", "1", 1) } else { unsetenv("MADEIRA_DOCK_OFFLINE") }
            return offline
        }
    }

    // MARK: Report

    static func reportURL(prefix: PrefixManager) -> URL {
        prefix.url.appendingPathComponent("drive_c/madeira-dock.txt")
    }

    /// The host's report: a bounded set of numeric fields, never arbitrary
    /// guest text.
    static let reportAllowed: Set<String> = ["probe-start-bits", "client-machine", "client-pe-timestamp",
        "load-client-begin", "load-client-error", "public-client021-present", "engine005-present",
        "engine-factory-result", "session-client-adapter", "session-unsupported-client", "session-user-method-mismatch",
        "session-private-abi-verified", "session-login-disabled", "session-native-handoff-invalid",
        "session-native-handoff-app-mismatch", "session-handoff-stage", "session-handoff-error",
        "session-account-input-invalid", "session-app-input-invalid",
        "session-native-token-submitted", "session-logon-start-result", "session-connection-result",
        "session-authenticated-online", "session-requested-app-entitled", "session-subscription-count",
        "session-requested-app-listed", "session-auth-test-result",
        "session-online-subscription-count", "session-online-app-zero-query", "session-online-callback-id",
        "session-timeout-subscription-count", "session-timeout-app-listed", "session-timeout-still-online",
        "session-online-blip", "session-online-blips", "session-online-lost", "session-entitlement-source",
        "session-offline-abi", "session-offline-requested", "session-offline-can", "session-offline-logon-result",
        "session-offline-logon-retry", "session-offline-logon-state", "session-offline-callback-id",
        "session-offline-entitled", "session-offline-listed", "session-offline-timeout-state",
        "session-offline-fallback", "session-offline-ready",
        "launch-client-error", "launch-option-index", "launch-option-invalid", "launch-option-missing",
        "launch-update-wait", "launch-update-retry", "launch-update-ready",
        "launch-config-wait", "launch-config-gave-up", "launch-session-wait", "launch-session-gave-up",
        "ceg-request", "ceg-request-result", "ceg-request-busy", "ceg-server-result", "ceg-job-result",
        "ceg-finished-jobs", "ceg-result", "ceg-disabled", "ceg-unsupported-client",
        "ceg-scm", "ceg-scm-started", "ceg-scm-error", "ceg-service-registered", "ceg-service-install", "ceg-service-stop", "ceg-scm-stopped",
        "game-scm", "game-scm-timeout", "launch-keep-alive",
        "shutdown-begin", "shutdown-complete", "probe-result"]
    /// The host's report rounds (madeira-dock src/main.c).
    static let reportRounds: Set<String> = ["ml1820", "ml1830", "ml1860", "ml1870", "ml1970", "ml1990", "ml2000", "ml2011", "ml2015", "ml2016"]

    static func parseReport(_ data: Data) -> [String: String] {
        guard data.count <= 32768, let text = String(data: data, encoding: .utf8) else { return [:] }
        var fields: [String: String] = [:]
        // Ignore a partial final line until the writer completes and flushes it.
        for line in text.replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false).dropLast() {
            let parts = line.split(separator: " ", omittingEmptySubsequences: false)
            guard parts.count == 3, parts[0] == "[steam-host]", reportRounds.contains(String(parts[1])) else { continue }
            let field = String(parts[2]).trimmingCharacters(in: .newlines).split(separator: "=", maxSplits: 1)
            guard field.count == 2 else { continue }
            let key = String(field[0]), value = String(field[1])
            if key == "client-sha256", value.utf8.count == 64,
               value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) {
                fields[key] = value
            } else if key == "session-callback-id", let number = Int32(value) {
                let ids = fields["session-callback-ids"]
                if (ids?.split(separator: ",").count ?? 0) < 16 {
                    fields["session-callback-ids"] = (ids.map { $0 + "," } ?? "") + String(number)
                }
            } else if reportAllowed.contains(key), let number = Int32(value) {
                fields[key] = String(number)
            }
        }
        return fields
    }

    private(set) static var lastReport: [String: String] = [:]

    /// Reads C:\madeira-dock.txt, logs what the session reported
    /// (`[dock-report]`, `[dock-report-file]`) and returns the fields. Safe to
    /// call when the file does not exist.
    @discardableResult
    static func readReport(prefix: PrefixManager) -> [String: String] {
        let url = reportURL(prefix: prefix)
        guard let data = try? Data(contentsOf: url), data.count <= 32768 else { return lastReport }
        let fields = parseReport(data)
        for key in fields.keys.sorted() where fields[key] != lastReport[key] {
            EngineLogStream.shared.append("[dock-report] \(key)=\(fields[key]!)")
        }
        if fields["probe-result"] != nil, lastReport["probe-result"] == nil {
            let lines = String(decoding: data, as: UTF8.self).split(separator: "\n").filter { $0.hasPrefix("[steam-host] ") }
            EngineLogStream.shared.append("[dock-report-file] lines=\(lines.count)")
            for line in lines.prefix(400) { EngineLogStream.shared.append("[dock-report-file] " + String(line).trimmingCharacters(in: .whitespacesAndNewlines)) }
        }
        lastReport = fields
        return fields
    }

    /// The honest reason a Dock launch did not end in a running game, in
    /// words, from the host's numeric report. Nil when the report shows no
    /// failure.
    static func humanFailure(_ fields: [String: String]) -> String? {
        guard let result = fields["probe-result"].flatMap(Int.init), result != 0 else { return nil }
        if result == 30 {
            if fields["session-unsupported-client"] == "1" || fields["session-user-method-mismatch"] != nil {
                return "Doz Dock does not support this Steam client build. Dock only drives client builds it has verified; the log has the client fingerprint and the failed check."
            }
            return "Doz Dock could not initialize the Steam session (code 30). Export the log to identify the failed check."
        }
        if result == 34 {
            return fields["session-authenticated-online"] == "1"
                ? "Steam signed in but did not confirm this game's license in time. Export the log before trying again."
                : "Steam did not finish signing in. Check the connection and try again."
        }
        if result == 35 { return "Steam did not confirm a license for this game on the signed-in account." }
        if result == 50 {
            return fields["session-offline-abi"] == "0"
                ? "There is no connection, and this Steam client build cannot be started offline by Doz Dock. Connect to the internet and try again."
                : "There is no connection, and Steam has nothing saved to sign this account in offline. Start a game once while online; Steam then allows offline starts until its offline sign-in expires."
        }
        if result == 51 { return "There is no connection, and Steam refused to sign in offline. Connect to the internet and start the game once." }
        if result == 52 { return "Steam signed in offline, but what it has saved does not list this game. Start this game once while online, then it can be played offline." }
        if result == 37 {
            if fields["session-native-handoff-app-mismatch"] == "1" {
                return "Doz Dock received a sign-in transfer for a different launch. Close the session and try again."
            }
            return "Doz Dock could not read the one-use Steam sign-in transfer. Steam has not checked the login yet. Export the log before trying again."
        }
        if result == 49 {
            switch fields["ceg-result"].flatMap(Int.init) {
            case -1: return "Steam took too long to prepare this game's executable. Check the connection and try again."
            case 0: return "Steam did not start preparing this game's executable. Verify the game's files with Steam, then try again."
            case 10: return "Steam is busy with this game (updating or running). Try again in a moment."
            case -4: return "Steam's Windows service manager could not be started, so Steam could not prepare this game's executable."
            default: return "Steam could not prepare this game's executable for your account (code \(fields["ceg-result"] ?? "?"))."
            }
        }
        if result == 45 || result == 48,
           fields["launch-option-missing"] != nil || fields["launch-option-invalid"] != nil {
            return "Steam rejected this game's launch option. Try again."
        }
        if result == 45 || result == 48, let error = fields["launch-client-error"].flatMap(Int.init),
           (22...23).contains(error), fields["launch-config-wait"] != nil {
            return "Steam did not finish loading this game's configuration after signing in. Wait a minute and start the game again."
        }
        if result == 45 || result == 48, fields["launch-client-error"] == "35", fields["launch-session-wait"] != nil {
            return "Steam still says this account is playing in another session. Close the game on your other device (or wait a few minutes after a closed session) and start it again."
        }
        if result == 45 || result == 48, let error = fields["launch-client-error"].flatMap(Int.init),
           let reason = launchRefusal(error, waited: result == 48) {
            return reason
        }
        return "Doz Dock could not complete the Steam launch (code \(result)). Export the log before trying again."
    }

    /// What the dock host is doing right now, in words, from the fields it has
    /// written so far. The report is append-only, so the newest stage wins by
    /// checking the late stages first. Nil when the host has not reported yet
    /// or the launch already failed (that path goes through `humanFailure`).
    static func progressStage(_ fields: [String: String]) -> String? {
        guard !fields.isEmpty else { return nil }
        if let result = fields["probe-result"].flatMap(Int.init), result != 0 { return nil }
        if fields["shutdown-begin"] != nil || fields["shutdown-complete"] != nil { return nil }

        if fields["launch-keep-alive"] != nil { return "Steam is running the game." }
        if fields["game-scm-timeout"] != nil { return "Steam is taking longer than usual to start the game — it has not given up." }
        if fields["game-scm"] != nil { return "Steam is starting the game…" }
        if fields["ceg-finished-jobs"] != nil || fields["ceg-result"] != nil || fields["ceg-job-result"] != nil
            || fields["ceg-server-result"] != nil {
            return "Steam prepared the game's files."
        }
        if fields["ceg-scm"] != nil || fields["ceg-request-result"] != nil || fields["ceg-request"] != nil {
            return "Steam is preparing the game's files…"
        }
        if fields["launch-session-wait"] != nil { return "Steam is loading the game's session…" }
        if fields["launch-config-wait"] != nil { return "Steam is loading the game's settings…" }
        if fields["launch-update-ready"] != nil { return "Steam is ready to start the game." }
        if fields["launch-update-wait"] != nil { return "Steam is updating its components…" }
        if fields["session-requested-app-listed"] != nil { return "Steam confirmed this game on your account." }
        if fields["session-requested-app-entitled"] != nil { return "Steam is confirming your license for this game…" }
        if fields["session-authenticated-online"] != nil || fields["session-offline-ready"] != nil {
            return "Steam signed in."
        }
        if fields["session-logon-start-result"] != nil || fields["session-connection-result"] != nil
            || fields["session-handoff-stage"] != nil {
            return "Signing in to Steam…"
        }
        if fields["load-client-error"] != nil { return "Steam's client reported an error while loading." }
        if fields["load-client-begin"] != nil { return "Loading Valve's Steam client — the first launch can take a few minutes." }
        if fields["probe-start-bits"] != nil { return "Starting Doz Dock…" }
        return nil
    }

    /// Valve's own launch refusal (EAppUpdateError) in words. Numbers only
    /// come from the host report; nothing here changes what Steam decided.
    static func launchRefusal(_ error: Int, waited: Bool) -> String? {
        switch error {
        case 5: return "Steam did not confirm a license for this game on the signed-in account."
        case 6, 21: return "Steam could not reach its servers to start this game. Check the connection and try again."
        case 16: return "Steam reports this game is already running. Close it, then try again."
        case 17, 19, 20:
            return waited
                ? "Steam could not finish installing content this game needs. Try again later."
                : "Steam needs to install or update content this game depends on before it can start. Start the game again to let Doz Dock wait for Steam."
        case 18: return "Steam does not see this game as installed."
        case 28: return "Steam could not find the game's executable."
        case 29: return "Steam started this game's program, but the engine could not load it (Steam reports an invalid platform). Export the log: it names the reason."
        case 22, 23, 24: return "Steam could not read this game's configuration. Try again."
        case 25: return "Steam says this game is not released yet."
        case 26: return "Steam says this game is not available in your region."
        case 35: return "Steam says this account is playing in another session. Close the game on your other device and start it again."
        default: return nil
        }
    }
}
