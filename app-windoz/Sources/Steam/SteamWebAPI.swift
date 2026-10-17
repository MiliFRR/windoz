// SPDX-License-Identifier: GPL-3.0-or-later
// Windoz — read-only reads of Steam's own web services for the game page.
//
// Sources (Valve's public Web API docs + live probes):
//   profile      GET api.steampowered.com/ISteamUserOAuth/GetTokenDetails/v1    [access_token]
//   stats        GET api.steampowered.com/ISteamUserStats/GetPlayerAchievements [access_token]
//   schema       GET .../ISteamUserStats/GetSchemaForGame/v2                     [access_token]
//   global %     GET .../ISteamUserStats/GetGlobalAchievementPercentagesForApp   [public]
//   friends      GET .../ISteamUser/GetFriendList/v1                             [access_token]
//   summaries    GET .../ISteamUser/GetPlayerSummaries/v2                        [access_token]
//
// Fallbacks when the Web API refuses the stored sign-in: the public community
// XML of the profile (works for public profiles, no token). "Owns this game"
// is that same public data (a profile's games list), checked for a bounded
// number of friends and cached; a private profile is reported as "not
// visible", never as "no".
//
// Everything here is read-only. Nothing is uploaded, and nothing talks to a
// Steam other than steam's own services.

import Foundation

enum SteamWebAPI {
    // MARK: - Errors

    enum APIError: LocalizedError, Equatable {
        case notSignedIn
        case refused(Int)
        case http(Int)
        case transport(String)
        case malformed(String)

        var errorDescription: String? {
            switch self {
            case .notSignedIn:
                return "Not signed in to Steam. Sign in from the Library tab first."
            case .refused(let code):
                return "Steam refused this call with the stored sign-in (HTTP \(code)). Signing out and back in refreshes the session token."
            case .http(let code):
                return "Steam answered HTTP \(code)."
            case .transport(let why):
                return "Could not reach Steam: \(why)"
            case .malformed(let why):
                return "Steam's answer was not what this call expects (\(why))."
            }
        }
    }

    // MARK: - Value types

    struct PlayerAchievement {
        var apiName: String
        var achieved: Bool
        var unlockTime: Date?
        // Filled by the community-XML fallback; the Web API path merges the
        // schema in.
        var displayName: String?
        var description: String?
        var icon: String?
        var grayIcon: String?
    }

    struct SchemaAchievement {
        var apiName: String
        var displayName: String
        var description: String
        var hidden: Bool
        var icon: String?
        var grayIcon: String?
    }

    struct Friend {
        var steamID: String
        var friendSince: Date?
    }

    struct PlayerSummary {
        var steamID: String
        var personaName: String
        var avatarURL: String?
        var state: Int
        var gameID: String?
        var gameName: String?
    }

    // MARK: - Session plumbing

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 12
        config.timeoutIntervalForResource = 20
        return URLSession(configuration: config)
    }()

    /// The JWT access token from the Keychain sign-in, or nil. Read-only;
    /// token refresh stays with the sign-in code.
    static func storedAccessToken() -> String? {
        SteamTokenStore().loadTokens()?.accessToken
    }

    /// The account's SteamID. Older sign-ins stored 0, so this falls back to
    /// the token itself — a Steam web token is a JWT whose `sub` claim is the
    /// SteamID — and only then asks Steam.
    static func steamID(accessToken: String) async throws -> String {
        if let stored = SteamTokenStore().loadTokens(), stored.steamID != 0 {
            return String(stored.steamID)
        }
        if let fromToken = steamIDFromJWT(accessToken) {
            SteamTokenStore().updateSteamID(UInt64(fromToken) ?? 0)
            return fromToken
        }
        let url = try makeURL(host: "api.steampowered.com", path: "/ISteamUserOAuth/GetTokenDetails/v1/",
                              query: ["access_token": accessToken])
        let json = try await getJSON(url)
        if let response = json["response"] as? [String: Any], let id = stringValue(response["steamid"]) {
            SteamTokenStore().updateSteamID(UInt64(id) ?? 0)
            return id
        }
        throw APIError.malformed("no steamid in GetTokenDetails")
    }

    static func steamIDFromJWT(_ token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload += "=" }
        guard let data = Data(base64Encoded: payload),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return stringValue(object["sub"])
    }

    private static func makeURL(host: String, path: String, query: [String: String]) throws -> URL {
        var comps = URLComponents()
        comps.scheme = "https"
        comps.host = host
        comps.path = path
        comps.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = comps.url else { throw APIError.malformed("bad URL \(host)\(path)") }
        return url
    }

    private static func getJSON(_ url: URL) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.setValue("windoz/\(AppContainer.displayVersion) (iOS)", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw APIError.malformed("no HTTP response") }
            if http.statusCode == 401 || http.statusCode == 403 { throw APIError.refused(http.statusCode) }
            guard (200..<300).contains(http.statusCode) else { throw APIError.http(http.statusCode) }
            guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                throw APIError.malformed("response is not JSON")
            }
            return object
        } catch let error as APIError {
            throw error
        } catch {
            throw APIError.transport(error.localizedDescription)
        }
    }

    private static func fetchData(_ url: URL) async -> Data? {
        var request = URLRequest(url: url)
        request.setValue("windoz/\(AppContainer.displayVersion) (iOS)", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
            return data
        } catch {
            return nil
        }
    }

    private static func stringValue(_ any: Any?) -> String? {
        if let s = any as? String, !s.isEmpty { return s }
        if let n = any as? NSNumber { return n.stringValue }
        return nil
    }

    // MARK: - Achievements

    static func playerAchievements(appID: Int, steamID: String, accessToken: String) async throws -> [PlayerAchievement] {
        let url = try makeURL(host: "api.steampowered.com", path: "/ISteamUserStats/GetPlayerAchievements/v0001/",
                              query: ["appid": String(appID), "steamid": steamID,
                                      "access_token": accessToken, "l": "english"])
        let json = try await getJSON(url)
        guard let stats = json["playerstats"] as? [String: Any] else { throw APIError.malformed("no playerstats") }
        if let success = stats["success"] as? Bool, !success {
            throw APIError.malformed(stringValue(stats["error"]) ?? "stats not available")
        }
        let list = stats["achievements"] as? [[String: Any]] ?? []
        return list.compactMap { item in
            guard let name = stringValue(item["apiname"]) else { return nil }
            let achieved = (item["achieved"] as? NSNumber)?.intValue == 1 || (item["achieved"] as? Bool) == true
            let ts = (item["unlocktime"] as? NSNumber)?.doubleValue ?? 0
            return PlayerAchievement(apiName: name, achieved: achieved,
                                     unlockTime: ts > 0 ? Date(timeIntervalSince1970: ts) : nil)
        }
    }

    static func schema(appID: Int, accessToken: String) async throws -> [SchemaAchievement] {
        let url = try makeURL(host: "api.steampowered.com", path: "/ISteamUserStats/GetSchemaForGame/v2/",
                              query: ["appid": String(appID), "access_token": accessToken, "l": "english"])
        let json = try await getJSON(url)
        guard let game = json["game"] as? [String: Any],
              let stats = game["availableGameStats"] as? [String: Any] else { throw APIError.malformed("no schema") }
        let list = stats["achievements"] as? [[String: Any]] ?? []
        return list.compactMap { item in
            guard let name = stringValue(item["name"]) else { return nil }
            return SchemaAchievement(apiName: name,
                                     displayName: stringValue(item["displayName"]) ?? name,
                                     description: stringValue(item["description"]) ?? "",
                                     hidden: (item["hidden"] as? NSNumber)?.intValue == 1,
                                     icon: stringValue(item["icon"]),
                                     grayIcon: stringValue(item["icongray"]))
        }
    }

    /// The share of all players who have each achievement. Public call — no
    /// sign-in needed.
    static func globalPercentages(appID: Int) async throws -> [String: Double] {
        let url = try makeURL(host: "api.steampowered.com",
                              path: "/ISteamUserStats/GetGlobalAchievementPercentagesForApp/v2/",
                              query: ["gameid": String(appID)])
        let json = try await getJSON(url)
        guard let wrap = json["achievementpercentages"] as? [String: Any],
              let list = wrap["achievements"] as? [[String: Any]] else { return [:] }
        var out: [String: Double] = [:]
        for item in list {
            if let name = stringValue(item["name"]), let pct = (item["percent"] as? NSNumber)?.doubleValue {
                out[name] = pct
            }
        }
        return out
    }

    // MARK: - Friends

    static func friendList(steamID: String, accessToken: String) async throws -> [Friend] {
        let url = try makeURL(host: "api.steampowered.com", path: "/ISteamUser/GetFriendList/v1/",
                              query: ["steamid": steamID, "access_token": accessToken, "relationship": "friend"])
        let json = try await getJSON(url)
        guard let wrap = json["friendslist"] as? [String: Any],
              let list = wrap["friends"] as? [[String: Any]] else { throw APIError.malformed("no friendslist") }
        return list.compactMap { item in
            guard let id = stringValue(item["steamid"]) else { return nil }
            let since = (item["friend_since"] as? NSNumber)?.doubleValue ?? 0
            return Friend(steamID: id, friendSince: since > 0 ? Date(timeIntervalSince1970: since) : nil)
        }
    }

    static func playerSummaries(_ ids: [String], accessToken: String) async throws -> [PlayerSummary] {
        guard !ids.isEmpty else { return [] }
        var out: [PlayerSummary] = []
        for start in stride(from: 0, to: ids.count, by: 100) {
            let chunk = Array(ids[start..<min(start + 100, ids.count)])
            let url = try makeURL(host: "api.steampowered.com", path: "/ISteamUser/GetPlayerSummaries/v2/",
                                  query: ["steamids": chunk.joined(separator: ","), "access_token": accessToken])
            let json = try await getJSON(url)
            guard let response = json["response"] as? [String: Any],
                  let players = response["players"] as? [[String: Any]] else { continue }
            for p in players {
                guard let id = stringValue(p["steamid"]) else { continue }
                out.append(PlayerSummary(steamID: id,
                                         personaName: stringValue(p["personaname"]) ?? "Steam friend",
                                         avatarURL: stringValue(p["avatarmedium"]) ?? stringValue(p["avatar"]),
                                         state: (p["personastate"] as? NSNumber)?.intValue ?? 0,
                                         gameID: stringValue(p["gameid"]),
                                         gameName: stringValue(p["gameextrainfo"])))
            }
        }
        return out
    }

    // MARK: - Community XML (public profiles — the fallback without a token)

    static func communityAchievements(steamID: String, appID: Int) async -> [PlayerAchievement]? {
        guard let url = URL(string: "https://steamcommunity.com/profiles/\(steamID)/stats/\(appID)?tab=achievements&xml=1")
        else { return nil }
        guard let data = await fetchData(url) else { return nil }
        let parser = AchievementXMLParser()
        guard parser.parse(data), !parser.achievements.isEmpty else { return nil }
        return parser.achievements
    }

    static func communityOwnedGames(steamID: String) async -> Set<Int>? {
        guard let url = URL(string: "https://steamcommunity.com/profiles/\(steamID)/games?tab=all&xml=1")
        else { return nil }
        guard let data = await fetchData(url) else { return nil }
        let parser = OwnedGamesXMLParser()
        guard parser.parse(data) else { return nil }
        return parser.privateProfile ? nil : parser.appIDs
    }

    /// The appids a public profile shows as owned, cached for 6 h. nil means
    /// "not visible" (private profile, or the request failed) — never "no".
    static func ownedGames(steamID: String) async -> Set<Int>? {
        if let cached = ownedCache.games(for: steamID) { return cached }
        guard let games = await communityOwnedGames(steamID: steamID) else { return nil }
        ownedCache.store(games, for: steamID)
        return games
    }

    private static let ownedCache = OwnedGamesCache()
}

/// Tiny in-memory cache for the owned-games scans (6 h TTL).
final class OwnedGamesCache: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String: (Date, Set<Int>)] = [:]
    private let ttl: TimeInterval = 6 * 3600

    func games(for id: String) -> Set<Int>? {
        lock.lock(); defer { lock.unlock() }
        guard let (date, games) = entries[id], Date().timeIntervalSince(date) < ttl else { return nil }
        return games
    }

    func store(_ games: Set<Int>, for id: String) {
        lock.lock()
        entries[id] = (Date(), games)
        lock.unlock()
    }
}

// MARK: - XML parsers

private final class AchievementXMLParser: NSObject, XMLParserDelegate {
    private(set) var achievements: [SteamWebAPI.PlayerAchievement] = []
    private var current: [String: String] = [:]
    private var closed = false
    private var buffer = ""

    func parse(_ data: Data) -> Bool {
        let parser = XMLParser(data: data)
        parser.delegate = self
        _ = parser.parse()
        return true
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String]) {
        buffer = ""
        if elementName == "achievement" {
            current = [:]
            let value = attributes["closed"] ?? ""
            closed = value == "1" || value.lowercased() == "true"
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { buffer += string }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if let text = String(data: CDATABlock, encoding: .utf8) { buffer += text }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName: String?) {
        let text = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        switch elementName {
        case "apiname": current["apiname"] = text
        case "name": current["name"] = text
        case "description": current["description"] = text
        case "iconOpen": current["iconOpen"] = text
        case "iconClosed": current["iconClosed"] = text
        case "unlockTimestamp": current["unlock"] = text
        case "achievement":
            if let name = current["apiname"], !name.isEmpty {
                let ts = TimeInterval(current["unlock"] ?? "") ?? 0
                achievements.append(SteamWebAPI.PlayerAchievement(
                    apiName: name,
                    achieved: closed,
                    unlockTime: ts > 0 ? Date(timeIntervalSince1970: ts) : nil,
                    displayName: current["name"],
                    description: current["description"],
                    icon: current["iconOpen"],
                    grayIcon: current["iconClosed"]))
            }
            current = [:]
        default:
            break
        }
        buffer = ""
    }
}

private final class OwnedGamesXMLParser: NSObject, XMLParserDelegate {
    private(set) var appIDs = Set<Int>()
    private(set) var privateProfile = false
    private var buffer = ""

    func parse(_ data: Data) -> Bool {
        let parser = XMLParser(data: data)
        parser.delegate = self
        return parser.parse()
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String]) {
        buffer = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { buffer += string }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName: String?) {
        let text = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        if elementName == "privacyState" { privateProfile = (text == "private") }
        if elementName == "appID", let id = Int(text) { appIDs.insert(id) }
        buffer = ""
    }
}

// MARK: - The game page's Steam model

/// Drives the Achievements and Friends tabs. Loads once per game, keeps what
/// it got, and reports failures in full sentences — the tabs never spin
/// forever and never claim more than Steam answered.
@MainActor
final class SteamGameInfoModel: ObservableObject {
    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    struct AchievementRow: Identifiable {
        let id: String
        let name: String
        let description: String
        let unlocked: Bool
        let unlockDate: Date?
        let iconURL: String?
        let grayIconURL: String?
        let globalPercent: Double?
    }

    struct OwnerRow: Identifiable {
        var id: String { friend.steamID }
        let friend: SteamWebAPI.Friend
        let summary: SteamWebAPI.PlayerSummary?
    }

    @Published private(set) var achievementsState: LoadState = .idle
    @Published private(set) var achievementRows: [AchievementRow] = []
    @Published private(set) var achievementSummary = ""
    @Published private(set) var achievementsFromCommunityXML = false

    @Published private(set) var friendsState: LoadState = .idle
    @Published private(set) var playingNow: [SteamWebAPI.PlayerSummary] = []
    @Published private(set) var owners: [OwnerRow] = []
    @Published private(set) var ownersVisible = 0
    @Published private(set) var ownersChecked = 0
    @Published private(set) var ownersTotal = 0

    private var achievementsKey: String?
    private var friendsKey: String?

    /// How many friends the (public-data) ownership scan checks per load.
    private static let ownershipScanLimit = 20
    private static let ownershipScanConcurrency = 4

    func loadAchievements(appID: Int) async {
        let key = "achv-\(appID)"
        if achievementsKey == key, achievementsState == .loaded { return }
        guard let token = SteamWebAPI.storedAccessToken() else {
            achievementsState = .failed(SteamWebAPI.APIError.notSignedIn.localizedDescription)
            return
        }
        achievementsState = .loading
        do {
            let steamID = try await SteamWebAPI.steamID(accessToken: token)
            do {
                async let playerTask = SteamWebAPI.playerAchievements(appID: appID, steamID: steamID, accessToken: token)
                async let schemaTask = SteamWebAPI.schema(appID: appID, accessToken: token)
                async let globalTask = SteamWebAPI.globalPercentages(appID: appID)
                let player = try await playerTask
                let schema = (try? await schemaTask) ?? []
                let global = (try? await globalTask) ?? [:]
                buildAchievementRows(player: player, schema: schema, global: global)
                achievementsFromCommunityXML = false
                achievementsKey = key
                achievementsState = .loaded
            } catch {
                if let fallback = await SteamWebAPI.communityAchievements(steamID: steamID, appID: appID),
                   !fallback.isEmpty {
                    buildAchievementRows(player: fallback, schema: [], global: [:])
                    achievementsFromCommunityXML = true
                    achievementsKey = key
                    achievementsState = .loaded
                } else {
                    achievementsState = .failed(Self.message(for: error))
                }
            }
        } catch {
            achievementsState = .failed(Self.message(for: error))
        }
    }

    func loadFriends(appID: Int) async {
        let key = "friends-\(appID)"
        if friendsKey == key, friendsState == .loaded { return }
        guard let token = SteamWebAPI.storedAccessToken() else {
            friendsState = .failed(SteamWebAPI.APIError.notSignedIn.localizedDescription)
            return
        }
        friendsState = .loading
        do {
            let steamID = try await SteamWebAPI.steamID(accessToken: token)
            let friends = try await SteamWebAPI.friendList(steamID: steamID, accessToken: token)
            ownersTotal = friends.count
            let ids = friends.prefix(200).map(\.steamID)
            let summaries = (try? await SteamWebAPI.playerSummaries(ids, accessToken: token)) ?? []
            let byID = Dictionary(summaries.map { ($0.steamID, $0) }, uniquingKeysWith: { first, _ in first })
            playingNow = summaries.filter { $0.gameID == String(appID) }

            let scanSet = Array(friends.prefix(Self.ownershipScanLimit))
            var found: [OwnerRow] = []
            ownersChecked = 0
            ownersVisible = 0
            let step = Self.ownershipScanConcurrency
            for start in stride(from: 0, to: scanSet.count, by: step) {
                let chunk = Array(scanSet[start..<min(start + step, scanSet.count)])
                await withTaskGroup(of: (String, Set<Int>?).self) { group in
                    for friend in chunk {
                        let id = friend.steamID
                        group.addTask { (id, await SteamWebAPI.ownedGames(steamID: id)) }
                    }
                    for await (id, games) in group {
                        ownersChecked += 1
                        guard let games else { continue }
                        ownersVisible += 1
                        if games.contains(appID),
                           let friend = scanSet.first(where: { $0.steamID == id }) {
                            found.append(OwnerRow(friend: friend, summary: byID[id]))
                        }
                    }
                }
            }
            owners = found.sorted { ($0.summary?.personaName ?? "") < ($1.summary?.personaName ?? "") }
            friendsKey = key
            friendsState = .loaded
        } catch {
            friendsState = .failed(Self.message(for: error))
        }
    }

    // MARK: Building rows

    private func buildAchievementRows(player: [SteamWebAPI.PlayerAchievement],
                                      schema: [SteamWebAPI.SchemaAchievement],
                                      global: [String: Double]) {
        let schemaBy = Dictionary(schema.map { ($0.apiName, $0) }, uniquingKeysWith: { first, _ in first })
        let playerBy = Dictionary(player.map { ($0.apiName, $0) }, uniquingKeysWith: { first, _ in first })
        let names = schema.isEmpty ? player.map(\.apiName) : schema.map(\.apiName)
        var rows: [AchievementRow] = []
        for name in names {
            let s = schemaBy[name]
            let p = playerBy[name]
            rows.append(AchievementRow(
                id: name,
                name: s?.displayName ?? p?.displayName ?? name,
                description: s?.description ?? p?.description ?? "",
                unlocked: p?.achieved ?? false,
                unlockDate: p?.unlockTime,
                iconURL: s?.icon ?? p?.icon,
                grayIconURL: s?.grayIcon ?? p?.grayIcon,
                globalPercent: global[name]))
        }
        achievementRows = rows.sorted { first, second in
            if first.unlocked != second.unlocked { return first.unlocked }
            return first.name.localizedCaseInsensitiveCompare(second.name) == .orderedAscending
        }
        let unlocked = rows.filter(\.unlocked).count
        achievementSummary = rows.isEmpty
            ? "Steam has no achievements for this game."
            : "\(unlocked) of \(rows.count) unlocked"
    }

    private static func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
