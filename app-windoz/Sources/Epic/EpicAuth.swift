// SPDX-License-Identifier: GPL-3.0-or-later
// Windoz — native Epic Games authentication.
//
// Device-code sign-in, verified against the live API (2026-10-17) and
// documented in MixV2/EpicResearch, "Authenticating by Device Code":
//
//   1. client token   POST /account/api/oauth/token             (client_credentials)
//   2. user code      POST /account/api/oauth/deviceAuthorization  (bearer)
//   3. approve        the owner opens epicgames.com/activate and enters the code
//   4. poll           POST /account/api/oauth/token             (device_code grant)
//
// The owner's password never touches Windoz: Epic issues the session only
// after the owner approves the code on Epic's own website. The refresh token
// is kept in the Keychain under "epic.session" and can be revoked by signing
// out here or from Epic's account page.
//
// The two client credentials below are Epic's own public credentials for its
// console (Switch) and desktop-launcher clients, published in the same public
// API research and used by the community the way Legendary uses the launcher
// client. Nothing is impersonated: the token belongs to the owner's account.
//
// Device-grant client, verified live 2026-10-17: Epic requires the *console*
// client for /deviceAuthorization — minting that bearer with the launcher
// client answers "Sorry, your client does not have the proper grant_type for
// access." (reproduced against the live API; the device screen showed exactly
// these words). The launcher client stays for the catalog metadata only.
//
// Open question for the downloads round: Epic's launcher/CDN endpoints are
// scoped to the launcher client (they answered 403 to a device-flow session
// during development), so depot downloads may need a second, launcher-scoped
// authorization (the code flow Legendary uses). That decision is deliberately
// deferred until downloads land — today's screen says what it does, no more.

import Foundation
import Combine

enum EpicAuthError: LocalizedError, Equatable {
    case authorizationPending      // the owner has not approved yet — keep polling
    case expiredDeviceCode
    case accessDenied
    case signInExpired             // the stored refresh token is no longer accepted
    case keychain
    case sessionIncomplete
    case http(status: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .authorizationPending:
            return "Waiting for Epic's approval."
        case .expiredDeviceCode:
            return "The code expired before it was approved. Start again for a fresh one."
        case .accessDenied:
            return "The approval was denied on Epic's side."
        case .signInExpired:
            return "Your Epic sign-in is no longer valid. Sign in again."
        case .keychain:
            return "Epic accepted the sign-in, but Windoz could not save it in this device's Keychain."
        case .sessionIncomplete:
            return "Epic's answer did not include a usable session."
        case .http(let status, let message):
            return message.isEmpty ? "Epic answered with an error (HTTP \(status))." : message
        }
    }
}

/// The stored Epic session. Only the refresh token is secret; the account id
/// and display name are carried along so the UI can show who is signed in
/// without another round trip.
enum EpicSignIn {
    /// Posted on the main queue after a sign-in is stored or removed.
    static let didChange = Notification.Name("WindozEpicSignInDidChange")

    struct StoredSession: Codable, Equatable {
        var refreshToken: String
        var accountId: String
        var displayName: String
    }

    private static let account = "epic.session"

    /// The session for the current run. Device test, 2026-10-17: the owner's
    /// sign-in reported success and the app flipped back to signed-out
    /// seconds later — the Keychain item written a moment earlier read back
    /// empty (see the [keychain] log lines for the raw OSStatus). The memory
    /// copy wins for this run, so a working Keychain changes nothing and a
    /// refusing one can no longer sign the user out mid-session; only a
    /// restart still needs the Keychain.
    private static var live: StoredSession?

    static func storedSession() -> StoredSession? {
        if let live { return live }
        BootTrace.mark("EpicSignIn.storedSession: keychain read")
        guard let data = Keychain.get(account: account) else {
            BootTrace.mark("EpicSignIn.storedSession: nothing stored")
            return nil
        }
        BootTrace.mark("EpicSignIn.storedSession: \(data.count) bytes")
        let session = try? JSONDecoder().decode(StoredSession.self, from: data)
        if let session { live = session }
        return session
    }

    static var isSignedIn: Bool { storedSession() != nil }

    static var accountName: String? {
        guard let session = storedSession() else { return nil }
        return session.displayName.isEmpty ? session.accountId : session.displayName
    }

    @discardableResult
    static func store(_ session: StoredSession) -> Bool {
        live = session
        guard let data = try? JSONEncoder().encode(session) else { return false }
        return Keychain.set(data, account: account)
    }

    @MainActor
    static func signOut() {
        live = nil
        Keychain.remove(account: account)
        EpicAuthClient.shared.clear()
        EpicLog.event("[epic-signin] signed out")
        notifyChange()
    }

    static func notifyChange() {
        DispatchQueue.main.async { NotificationCenter.default.post(name: didChange, object: nil) }
    }
}

/// Protocol-level logging, shaped like the Steam client's (`SteamLog`): events
/// are low-volume and always on; traces are off unless WINDOZ_EPIC_TRACE=1.
/// Never logged: tokens, device codes, user codes, account ids, payload bytes.
enum EpicLog {
    static let tracing = ProcessInfo.processInfo.environment["WINDOZ_EPIC_TRACE"].map { $0.trimmingCharacters(in: .whitespaces) != "0" } ?? false

    static func trace(_ message: @autoclosure () -> String) {
        guard tracing else { return }
        EngineLogStream.shared.append("[epic-trace] " + message())
    }

    static func event(_ message: String) {
        EngineLogStream.shared.append(message)
    }
}

/// The HTTP layer of Epic's account service. All requests are small JSON/form
/// calls; tokens are only ever sent as the Authorization header over HTTPS.
enum EpicAuth {
    static let oauthHost = "account-public-service-prod03.ol.epicgames.com"

    /// Epic's public console-client credentials (device-code grant).
    static let deviceClient = (id: "98f7e42c2e3a4f86a74eb43fbb41ed39",
                               secret: "0a2449a2-001a-451e-afec-3e812901c4d7")
    /// Epic's public launcher-client credentials — used only for the catalog
    /// metadata calls, which accept client credentials (verified live).
    static let catalogClient = (id: "34a02cf8f4414e29b15921876da36f9a",
                                secret: "daafbccc737745039dffe53d94fc76cf")

    struct DeviceAuthorization: Codable {
        let user_code: String
        let device_code: String
        let verification_uri: String
        let verification_uri_complete: String?
        let expires_in: Double
        let interval: Double?
    }

    struct Token: Codable {
        let access_token: String
        let refresh_token: String?
        let expires_in: Double?
        let account_id: String?
        let displayName: String?
        let token_type: String?
    }

    private struct ErrorBody: Codable {
        let errorCode: String?
        let errorMessage: String?
        let error: String?
    }

    // MARK: - Requests

    /// Step 1+2: get a client token (console client — the device grant is not
    /// allowed to the launcher client), then ask Epic for a user code.
    static func requestDeviceAuthorization() async throws -> DeviceAuthorization {
        let clientToken = try await clientCredentialsToken(client: deviceClient)
        var request = URLRequest(url: URL(string: "https://\(oauthHost)/account/api/oauth/deviceAuthorization")!)
        request.httpMethod = "POST"
        request.setValue("bearer \(clientToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formBody([("prompt", "login")])
        let data = try await send(request)
        return try JSONDecoder().decode(DeviceAuthorization.self, from: data)
    }

    /// Step 4: one poll of the device-code grant. `authorizationPending` while
    /// the owner has not approved; the session when they have.
    static func pollDeviceCode(_ deviceCode: String) async throws -> Token {
        try await tokenRequest(grant: [
            ("grant_type", "device_code"),
            ("device_code", deviceCode),
            ("token_type", "eg1"),
        ], client: deviceClient)
    }

    /// Refresh an expired access token with the stored refresh token.
    static func refresh(refreshToken: String) async throws -> Token {
        try await tokenRequest(grant: [
            ("grant_type", "refresh_token"),
            ("refresh_token", refreshToken),
            ("token_type", "eg1"),
        ], client: deviceClient)
    }

    /// A client-credentials token for the catalog calls (no user context).
    static func clientCredentialsToken() async throws -> String {
        try await clientCredentialsToken(client: catalogClient)
    }

    /// A client-credentials token for a specific client.
    static func clientCredentialsToken(client: (id: String, secret: String)) async throws -> String {
        let token = try await tokenRequest(grant: [
            ("grant_type", "client_credentials"),
            ("token_type", "eg1"),
        ], client: client)
        return token.access_token
    }

    // MARK: - Plumbing

    private static func tokenRequest(grant: [(String, String)], client: (id: String, secret: String)) async throws -> Token {
        var request = URLRequest(url: URL(string: "https://\(oauthHost)/account/api/oauth/token")!)
        request.httpMethod = "POST"
        request.setValue("basic " + basicCredential(client), forHTTPHeaderField: "Authorization")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formBody(grant)
        let data = try await send(request)
        return try JSONDecoder().decode(Token.self, from: data)
    }

    private static func send(_ request: URLRequest) async throws -> Data {
        var request = request
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status < 400 else {
            let body = try? JSONDecoder().decode(ErrorBody.self, from: data)
            let code = body?.errorCode ?? body?.error ?? ""
            let message = body?.errorMessage ?? ""
            EpicLog.trace("[epic-auth] http \(status) \(code)")
            if status == 400 || status == 401 {
                if code.contains("authorization_pending") { throw EpicAuthError.authorizationPending }
                if code.contains("expired") { throw EpicAuthError.expiredDeviceCode }
                if code.contains("access_denied") { throw EpicAuthError.accessDenied }
                if code.contains("invalid_grant") || code.contains("invalid_token") || code.contains("invalid_refresh")
                    || code.contains("unauthorized") { throw EpicAuthError.signInExpired }
            }
            throw EpicAuthError.http(status: status, message: message)
        }
        return data
    }

    static func basicCredential(_ client: (id: String, secret: String)) -> String {
        Data("\(client.id):\(client.secret)".utf8).base64EncodedString()
    }

    private static func formBody(_ pairs: [(String, String)]) -> Data {
        Data(pairs.map { "\($0.0)=\(encode($0.1))" }.joined(separator: "&").utf8)
    }

    private static func encode(_ value: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}

/// The access-token cache. Windoz holds at most one account; every call
/// refreshes on demand and rotates the stored refresh token when Epic sends a
/// new one (tokens are single-use in this family of grants).
@MainActor
final class EpicAuthClient {
    static let shared = EpicAuthClient()

    private var accessToken: String?
    private var accessExpiry: Date = .distantPast
    private var clientToken: String?
    private var clientExpiry: Date = .distantPast

    func adopt(accessToken: String, expiresIn: Double) {
        self.accessToken = accessToken
        accessExpiry = Date().addingTimeInterval(max(60, expiresIn - 120))
    }

    func clear() {
        accessToken = nil
        accessExpiry = .distantPast
    }

    /// A valid user access token, refreshing with the stored session.
    func userToken() async throws -> String {
        if let accessToken, Date() < accessExpiry { return accessToken }
        guard let session = EpicSignIn.storedSession(), !session.refreshToken.isEmpty else {
            throw EpicAuthError.signInExpired
        }
        do {
            let token = try await EpicAuth.refresh(refreshToken: session.refreshToken)
            adopt(accessToken: token.access_token, expiresIn: token.expires_in ?? 3600)
            var updated = session
            if let rotated = token.refresh_token, !rotated.isEmpty { updated.refreshToken = rotated }
            if let name = token.displayName, !name.isEmpty { updated.displayName = name }
            updated.accountId = session.accountId.isEmpty ? (token.account_id ?? "") : session.accountId
            EpicSignIn.store(updated)
            return token.access_token
        } catch EpicAuthError.signInExpired {
            EpicSignIn.signOut()
            throw EpicAuthError.signInExpired
        }
    }

    /// A client-credentials token for catalog calls (cached ~1h).
    func clientCredentials() async throws -> String {
        if let clientToken, Date() < clientExpiry { return clientToken }
        let token = try await EpicAuth.clientCredentialsToken()
        clientToken = token
        clientExpiry = Date().addingTimeInterval(3000)
        return token
    }
}

/// Drives one device-code sign-in for the UI: request a code, show it, poll
/// until the owner approves on Epic's site (or it expires / is cancelled).
@MainActor
final class EpicSignInController: ObservableObject {
    enum Stage: Equatable {
        case idle
        case requesting
        case waiting(userCode: String, verificationURL: String, expiresAt: Date)
        case finishing
        case done
        case failed(String)
    }

    @Published private(set) var stage: Stage = .idle

    private var task: Task<Void, Never>?

    var isBusy: Bool {
        switch stage {
        case .requesting, .waiting, .finishing: return true
        case .idle, .done, .failed: return false
        }
    }

    func begin() {
        guard !isBusy else { return }
        task?.cancel()
        stage = .requesting
        task = Task { [weak self] in
            guard let self else { return }
            await self.run()
        }
    }

    /// Stops the poll loop (sheet dismissed, or "Cancel" tapped). A finished
    /// sign-in is left alone so the success state can settle first.
    func cancel() {
        task?.cancel()
        task = nil
        if stage != .done { stage = .idle }
    }

    private func run() async {
        do {
            let authorization = try await EpicAuth.requestDeviceAuthorization()
            guard !Task.isCancelled else { return }
            let url = authorization.verification_uri_complete ?? authorization.verification_uri
            let deadline = Date().addingTimeInterval(max(60, authorization.expires_in))
            stage = .waiting(userCode: authorization.user_code, verificationURL: url, expiresAt: deadline)
            EpicLog.event("[epic-signin] device code issued, waiting for approval")

            let interval = UInt64(max(5, authorization.interval ?? 10))
            while !Task.isCancelled {
                if Date() >= deadline { throw EpicAuthError.expiredDeviceCode }
                try await Task.sleep(nanoseconds: interval * 1_000_000_000)
                if Task.isCancelled { return }
                do {
                    let token = try await EpicAuth.pollDeviceCode(authorization.device_code)
                    try await finish(token)
                    return
                } catch EpicAuthError.authorizationPending {
                    continue
                }
            }
        } catch is CancellationError {
            // Cancelled by the sheet going away; keep the stage as-is.
        } catch {
            stage = .failed(Self.describe(error))
            EpicLog.event("[epic-signin] sign-in failed: \(Self.describe(error))")
        }
    }

    private func finish(_ token: EpicAuth.Token) async throws {
        stage = .finishing
        guard let refresh = token.refresh_token, !refresh.isEmpty else {
            throw EpicAuthError.sessionIncomplete
        }
        let session = EpicSignIn.StoredSession(
            refreshToken: refresh,
            accountId: token.account_id ?? "",
            displayName: token.displayName ?? "")
        let persisted = EpicSignIn.store(session)
        EpicAuthClient.shared.adopt(accessToken: token.access_token, expiresIn: token.expires_in ?? 3600)
        stage = .done
        EpicLog.event(persisted
            ? "[epic-signin] sign-in stored"
            : "[epic-signin] sign-in stored for this run only — the Keychain refused to save it (see [keychain] lines); a restart will ask to sign in again")
        EpicSignIn.notifyChange()
    }

    private static func describe(_ error: Error) -> String {
        if let epic = error as? EpicAuthError { return epic.errorDescription ?? "Epic sign-in failed." }
        return error.localizedDescription
    }
}
