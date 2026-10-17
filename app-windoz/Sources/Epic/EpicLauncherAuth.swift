// SPDX-License-Identifier: GPL-3.0-or-later
// Windoz — Epic's launcher-scoped sign-in (the web code flow).
//
// Why this exists next to the device-code sign-in: Epic scopes its
// launcher/library services to the launcher client, and the device-flow
// console session is refused there (HTTP 403, seen live 2026-10-17). This
// flow runs in a WKWebView against Epic's own pages:
//
//   1. load   https://www.epicgames.com/id/login?redirectUrl=...
//             (redirectUrl = .../id/api/redirect?clientId=<launcher>&responseType=code)
//   2. the owner signs in on Epic's page — the password never touches Windoz
//   3. Epic answers the redirectUrl with a JSON page carrying the code. The
//      owner's device run (2026-10-18) showed the code rendered in the page
//      *body* (`{"warning":"Do not share this code…", "code":"…"}`), not as a
//      `?code=` query — so the sheet reads the body, and also takes a query
//      code when a flow delivers one that way
//   4. exchange  POST /account/api/oauth/token  (authorization_code grant,
//                launcher client, token_type=eg1)
//
// The session lives in the Keychain under "epic.launcher.session" and can be
// revoked by signing out here or from Epic's account page. The web view keeps
// no cookies (a non-persistent store), so nothing carries over between
// attempts.

import Foundation
import Combine
import SwiftUI
import UIKit
import WebKit

/// The stored launcher session. Only the refresh token is secret; the account
/// id and display name ride along so the UI can show who is signed in without
/// another round trip. Same memory-copy-wins rule as the device session: if
/// the Keychain refuses to save, the run still works and a restart asks again.
enum EpicLauncherSignIn {
    /// Posted on the main queue after a launcher sign-in is stored or removed.
    static let didChange = Notification.Name("WindozEpicLauncherSignInDidChange")

    struct StoredSession: Codable, Equatable {
        var refreshToken: String
        var accountId: String
        var displayName: String
    }

    private static let account = "epic.launcher.session"
    private static var live: StoredSession?

    static func storedSession() -> StoredSession? {
        if let live { return live }
        guard let data = Keychain.get(account: account) else { return nil }
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
        EpicLauncherAuthClient.shared.clear()
        EpicLog.event("[epic-launcher] signed out")
        notifyChange()
    }

    static func notifyChange() {
        DispatchQueue.main.async { NotificationCenter.default.post(name: didChange, object: nil) }
    }
}

/// The flow's fixed pieces: the URL Epic is asked to redirect to, the login
/// page that carries it, and the code exchange.
enum EpicLauncherAuth {
    static let redirectURL = "https://www.epicgames.com/id/api/redirect"

    /// The page the web view opens. Epic answers `redirectURL` with a JSON page
    /// once the owner is signed in; the web view either intercepts a navigation
    /// that carries `?code=...` or reads the code out of the page's body (see
    /// `authorizationCode(fromPageText:)`).
    static var loginURL: URL {
        var redirect = URLComponents(string: redirectURL)!
        redirect.queryItems = [
            URLQueryItem(name: "clientId", value: EpicAuth.catalogClient.id),
            URLQueryItem(name: "responseType", value: "code"),
        ]
        var page = URLComponents(string: "https://www.epicgames.com/id/login")!
        page.queryItems = [URLQueryItem(name: "redirectUrl", value: redirect.url?.absoluteString ?? redirectURL)]
        return page.url!
    }

    /// The code page: the URL Epic lands on when it has an answer for us.
    static func isCodePage(_ url: URL) -> Bool {
        url.host == "www.epicgames.com" && url.path == "/id/api/redirect"
    }

    /// The authorization code carried by a redirect navigation, when the code
    /// is in the URL itself.
    static func authorizationCode(from url: URL) -> String? {
        guard isCodePage(url) else { return nil }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "code" })?.value
    }

    /// The code inside the redirect page's JSON body. WebKit renders that
    /// response as text, so the body's text is the JSON; the parser accepts it
    /// with or without surrounding text and accepts both key spellings Epic
    /// has shipped (`code`, `authorizationCode`).
    static func authorizationCode(fromPageText text: String) -> String? {
        if let data = text.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for key in ["authorizationCode", "code"] {
                if let value = object[key] as? String, !value.isEmpty { return value }
            }
        }
        // The page may wrap the JSON in other text; take the first
        // JSON-looking `"key":"value"` pair.
        for key in ["authorizationCode", "code"] {
            let pattern = "\"\(key)\"\\s*:\\s*\"([A-Za-z0-9\\-_.]+)\""
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
               match.numberOfRanges == 2,
               let range = Range(match.range(at: 1), in: text) {
                return String(text[range])
            }
        }
        return nil
    }

    /// Exchange the code for a session (launcher client, authorization_code
    /// grant).
    static func exchange(code: String) async throws -> EpicAuth.Token {
        try await EpicAuth.authorizationCodeToken(code: code)
    }
}

/// The launcher access-token cache. Mirrors `EpicAuthClient`: refresh on
/// demand, rotate the stored refresh token when Epic sends a new one.
@MainActor
final class EpicLauncherAuthClient {
    static let shared = EpicLauncherAuthClient()

    private var accessToken: String?
    private var accessExpiry: Date = .distantPast

    func adopt(accessToken: String, expiresIn: Double) {
        self.accessToken = accessToken
        accessExpiry = Date().addingTimeInterval(max(60, expiresIn - 120))
    }

    func clear() {
        accessToken = nil
        accessExpiry = .distantPast
    }

    /// A valid launcher access token, refreshing with the stored launcher
    /// session. Throws `.signInExpired` (and signs out) when Epic no longer
    /// accepts the refresh token.
    func userToken() async throws -> String {
        if let accessToken, Date() < accessExpiry { return accessToken }
        guard let session = EpicLauncherSignIn.storedSession(), !session.refreshToken.isEmpty else {
            throw EpicAuthError.signInExpired
        }
        do {
            let token = try await EpicAuth.refreshLauncher(refreshToken: session.refreshToken)
            adopt(accessToken: token.access_token, expiresIn: token.expires_in ?? 3600)
            var updated = session
            if let rotated = token.refresh_token, !rotated.isEmpty { updated.refreshToken = rotated }
            if let name = token.displayName, !name.isEmpty { updated.displayName = name }
            updated.accountId = session.accountId.isEmpty ? (token.account_id ?? "") : session.accountId
            EpicLauncherSignIn.store(updated)
            return token.access_token
        } catch EpicAuthError.signInExpired {
            EpicLauncherSignIn.signOut()
            throw EpicAuthError.signInExpired
        }
    }
}

/// One launcher sign-in: the web view reports the redirect, this exchanges it
/// and stores the session. The states are deliberately few.
@MainActor
final class EpicLauncherSignInController: ObservableObject {
    enum Stage: Equatable {
        case web
        case finishing
        case done
        case failed(String)
    }

    @Published private(set) var stage: Stage = .web
    private var running = false

    func handle(code: String) {
        guard !running else { return }
        running = true
        stage = .finishing
        Task {
            do {
                let token = try await EpicLauncherAuth.exchange(code: code)
                guard let refresh = token.refresh_token, !refresh.isEmpty else {
                    throw EpicAuthError.sessionIncomplete
                }
                let session = EpicLauncherSignIn.StoredSession(
                    refreshToken: refresh,
                    accountId: token.account_id ?? "",
                    displayName: token.displayName ?? "")
                let persisted = EpicLauncherSignIn.store(session)
                EpicLauncherAuthClient.shared.adopt(accessToken: token.access_token,
                                                    expiresIn: token.expires_in ?? 3600)
                stage = .done
                EpicLog.event(persisted
                    ? "[epic-launcher] library session stored"
                    : "[epic-launcher] library session stored for this run only — the Keychain refused to save it")
                EpicLauncherSignIn.notifyChange()
            } catch {
                stage = .failed(Self.describe(error))
                EpicLog.event("[epic-launcher] sign-in failed: \(Self.describe(error))")
            }
            running = false
        }
    }

    func handleNavigationFailure(_ text: String) {
        guard case .web = stage else { return }
        stage = .failed(text)
    }

    func retry() {
        running = false
        stage = .web
    }

    private static func describe(_ error: Error) -> String {
        if let epic = error as? EpicAuthError { return epic.errorDescription ?? "Epic sign-in failed." }
        return error.localizedDescription
    }
}

// MARK: - The sheet

/// The launcher sign-in sheet: Epic's page in a cookie-less web view, then the
/// exchange, then the stored session.
struct EpicLauncherSignInSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var controller = EpicLauncherSignInController()

    var body: some View {
        NavigationStack {
            ZStack {
                ConsoleBackground()
                switch controller.stage {
                case .web:
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Sign in on Epic's own page. Windoz never sees the password, keeps no cookies, and stores only the session Epic hands back.")
                            .font(.caption).foregroundStyle(.white.opacity(0.6))
                            .padding(.horizontal, 14)
                        EpicLauncherWebView(
                            url: EpicLauncherAuth.loginURL,
                            onCode: { controller.handle(code: $0) },
                            onFailure: { controller.handleNavigationFailure($0) })
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .padding(.horizontal, 14)
                            .padding(.bottom, 8)
                    }
                    .padding(.top, 8)
                case .finishing:
                    HStack(spacing: 10) {
                        ProgressView().tint(.white)
                        Text("Saving the session Epic issued…")
                            .font(.footnote).foregroundStyle(.white.opacity(0.75))
                    }
                case .done:
                    VStack(spacing: 12) {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 44)).foregroundStyle(Theme.ok)
                        Text("Signed in\(EpicLauncherSignIn.accountName.map { " as \($0)" } ?? "")")
                            .font(.headline).foregroundStyle(.white)
                        Text("The library now uses this launcher session.")
                            .font(.caption).foregroundStyle(.white.opacity(0.55))
                    }
                case .failed(let why):
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 40)).foregroundStyle(Theme.warn)
                        Text(why)
                            .font(.footnote).foregroundStyle(.white.opacity(0.75))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                        Button("Try again") { controller.retry() }
                            .buttonStyle(.bordered)
                            .tint(Theme.accent)
                    }
                }
            }
            .navigationTitle("Epic launcher sign-in")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .onChange(of: controller.stage) { _, newValue in
            if newValue == .done {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { dismiss() }
            }
        }
    }
}

// MARK: - The web view

/// Epic's page in a cookie-less web view. Two rules: a navigation that carries
/// `?code=...` is caught and never loaded; the code page itself is allowed to
/// render and its body is read for the JSON answer (device report
/// 2026-10-18 — the code arrives in the page body).
struct EpicLauncherWebView: UIViewRepresentable {
    let url: URL
    let onCode: (String) -> Void
    let onFailure: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()   // no cookies survive this sheet
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = false
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        private let parent: EpicLauncherWebView
        private var finished = false
        private var codeReads = 0

        init(_ parent: EpicLauncherWebView) { self.parent = parent }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if let url = navigationAction.request.url,
               let code = EpicLauncherAuth.authorizationCode(from: url) {
                decisionHandler(.cancel)
                complete(code)
                return
            }
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // The code page answers with a JSON body; read it instead of
            // waiting for a navigation that may never carry a query code.
            guard !finished, let url = webView.url, EpicLauncherAuth.isCodePage(url) else { return }
            readCode(from: webView)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                     withError error: Error) {
            parent.onFailure("Epic's page could not load: \(error.localizedDescription)")
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            parent.onFailure("Epic's page failed while loading: \(error.localizedDescription)")
        }

        /// Read the code page's body text. The JSON may take a moment to
        /// render, so this retries briefly; `finished` stops every path once
        /// a code was handed up.
        private func readCode(from webView: WKWebView) {
            guard !finished else { return }
            guard codeReads < 15 else {
                parent.onFailure("The sign-in page answered without a code Windoz could read. Try again — the final page should show a JSON answer.")
                return
            }
            codeReads += 1
            let script = "(document.body && document.body.innerText) || "
                + "(document.documentElement && document.documentElement.textContent) || ''"
            webView.evaluateJavaScript(script) { [weak self] value, _ in
                guard let self, !self.finished else { return }
                if let text = value as? String,
                   let code = EpicLauncherAuth.authorizationCode(fromPageText: text) {
                    self.complete(code)
                    return
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                    guard let self, !self.finished else { return }
                    self.readCode(from: webView)
                }
            }
        }

        private func complete(_ code: String) {
            guard !finished else { return }
            finished = true
            parent.onCode(code)
        }
    }
}
