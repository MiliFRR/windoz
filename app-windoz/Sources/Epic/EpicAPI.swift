// SPDX-License-Identifier: GPL-3.0-or-later
// Windoz — Epic's owned-library and catalog metadata calls.
//
// Sources: Legendary's api/egs.py (MIT, derrod) for the request shapes, and
// live probes of Epic's services (2026-10-17) for what answers what:
//
//   library  GET  https://library-service.live.use1a.on.epicgames.com
//                   /library/api/public/items?includeMetadata=true   [bearer user]
//   catalog  GET  https://catalog-public-service-prod06.ol.epicgames.com
//                   /catalog/api/shared/namespace/{ns}/bulk/items?id=... [bearer client]
//
// The library call is the owner's own entitlement list; the catalog call only
// fetches public store metadata (title, developer, art) and needs no account
// context, which is why it uses client credentials. No downloads happen here —
// this layer is read-only.

import Foundation

enum EpicAPI {
    static let libraryHost = "library-service.live.use1a.on.epicgames.com"
    static let catalogHost = "catalog-public-service-prod06.ol.epicgames.com"
    static let launcherHost = "launcher-public-service-prod06.ol.epicgames.com"

    struct LibraryItem: Codable, Hashable {
        let namespace: String
        let catalogItemId: String
        let appName: String?
        let productId: String?
        let sandboxName: String?
    }

    private struct LibraryResponse: Codable {
        struct Meta: Codable { let nextCursor: String? }
        let records: [LibraryItem]
        let responseMetadata: Meta?
    }

    struct CatalogItem: Codable {
        struct KeyImage: Codable { let type: String; let url: String }
        struct Category: Codable { let path: String }
        let title: String?
        let developer: String?
        let keyImages: [KeyImage]?
        let categories: [Category]?
    }

    // MARK: - Owned library

    /// Every item in the account's Epic library, cursors followed.
    static func libraryItems(userToken: String) async throws -> [LibraryItem] {
        var items: [LibraryItem] = []
        var cursor: String?
        var pages = 0
        repeat {
            var components = URLComponents()
            components.scheme = "https"
            components.host = libraryHost
            components.path = "/library/api/public/items"
            var query = [URLQueryItem(name: "includeMetadata", value: "true")]
            if let cursor { query.append(URLQueryItem(name: "cursor", value: cursor)) }
            components.queryItems = query
            guard let url = components.url else { throw EpicAuthError.sessionIncomplete }
            var request = URLRequest(url: url)
            request.setValue("bearer \(userToken)", forHTTPHeaderField: "Authorization")
            let data = try await send(request)
            let page = try JSONDecoder().decode(LibraryResponse.self, from: data)
            items.append(contentsOf: page.records)
            cursor = page.responseMetadata?.nextCursor
            pages += 1
        } while cursor != nil && pages < 50 && items.count < 4000
        return items
    }

    // MARK: - Catalog metadata (title, developer, art)

    /// Public store metadata for one catalog item. Nil when the item has no
    /// catalog entry (rare; callers fall back to the app name).
    static func catalogItem(namespace: String, catalogItemId: String, clientToken: String) async throws -> CatalogItem? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = catalogHost
        components.path = "/catalog/api/shared/namespace/\(pathSegment(namespace))/bulk/items"
        components.queryItems = [
            URLQueryItem(name: "id", value: catalogItemId),
            URLQueryItem(name: "country", value: "US"),
            URLQueryItem(name: "locale", value: "en"),
        ]
        guard let url = components.url else { throw EpicAuthError.sessionIncomplete }
        var request = URLRequest(url: url)
        request.setValue("bearer \(clientToken)", forHTTPHeaderField: "Authorization")
        let data = try await send(request, authScoped: false)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entry = object[catalogItemId] else { return nil }
        let entryData = try JSONSerialization.data(withJSONObject: entry)
        return try JSONDecoder().decode(CatalogItem.self, from: entryData)
    }

    /// Catalogue art: the tall box is the library tile, the wide box the hero.
    static func coverURL(_ item: CatalogItem) -> URL? {
        pick(item, preferred: ["DieselGameBoxTall", "OfferImageTall", "Thumbnail", "DieselStoreFrontTall"])
    }

    static func heroURL(_ item: CatalogItem) -> URL? {
        pick(item, preferred: ["DieselGameBox", "OfferImageWide", "DieselStoreFrontWide", "Featured"])
    }

    /// True when the catalog says this is an installable application or game
    /// (as opposed to an add-on or an entitlement-only record).
    static func looksInstallable(_ item: CatalogItem) -> Bool {
        guard let categories = item.categories, !categories.isEmpty else { return true }
        return categories.contains { $0.path.lowercased() == "games" || $0.path.lowercased() == "applications" }
    }

    private static func pick(_ item: CatalogItem, preferred: [String]) -> URL? {
        guard let images = item.keyImages else { return nil }
        for type in preferred {
            if let match = images.first(where: { $0.type == type }), let url = URL(string: match.url) {
                return url
            }
        }
        return nil
    }

    // MARK: - Asset manifests (the download path)

    /// One `elements` entry of launcher-public-service's assets response —
    /// assembled by `EpicProtocol.parseAssetElements` (lenient on purpose;
    /// see that function's comment for why this is not Codable).
    typealias AssetElement = EpicProtocol.AssetElement

    /// The live Windows build manifest for one owned item: the URL to fetch
    /// (the API's signed query params joined on verbatim — re-encoding them
    /// would break the signature), the SHA-1 the launcher service recorded for
    /// the manifest's bytes, and the build version. Nil means Epic answered
    /// for this item with no manifest at all.
    struct AssetManifest {
        let url: URL
        let sha1: String?
        let buildVersion: String?
    }

    /// Tries the v2 endpoint by namespace + catalog item + app name (the
    /// launcher's own request shape), then without the app name, then the v1
    /// per-platform list filtered to this item. The bearer must be a
    /// launcher-scoped session; anything else is refused with Epic's status.
    static func assetManifest(namespace: String, catalogItemId: String,
                              appName: String?, userToken: String) async throws -> AssetManifest? {
        var attempts: [URL] = []
        if let appName, !appName.isEmpty,
           let url = assetsURL(namespace: namespace, catalogItemId: catalogItemId, appName: appName) {
            attempts.append(url)
        }
        if let url = assetsURL(namespace: namespace, catalogItemId: catalogItemId, appName: nil) {
            attempts.append(url)
        }
        if let v1 = v1AssetsURL() { attempts.append(v1) }

        var lastError: Error?
        for url in attempts {
            do {
                let elements = try await assetElements(url: url, userToken: userToken)
                guard !elements.isEmpty else { continue }
                let match = elements.first { element in
                    element.catalogItemId?.caseInsensitiveCompare(catalogItemId) == .orderedSame
                        || (appName.map { element.appName?.caseInsensitiveCompare($0) == .orderedSame } ?? false)
                } ?? elements.first
                guard let match, let ref = manifestRef(match), let manifest = manifestURL(ref) else { continue }
                return AssetManifest(url: manifest, sha1: match.hash, buildVersion: match.buildVersion)
            } catch {
                lastError = error
            }
        }
        if let lastError { throw lastError }
        return nil
    }

    private static func assetElements(url: URL, userToken: String) async throws -> [AssetElement] {
        var request = URLRequest(url: url)
        request.setValue("bearer \(userToken)", forHTTPHeaderField: "Authorization")
        request.setValue("UELauncher/11.0.1-14907503+++Portal+Release-Live Windows/10.0.19041.1.256.64bit",
                         forHTTPHeaderField: "User-Agent")
        let data = try await send(request, authScoped: false)
        return EpicProtocol.parseAssetElements(data)
    }

    private static func assetsURL(namespace: String, catalogItemId: String, appName: String?) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = launcherHost
        var path = "/launcher/api/public/assets/v2/platform/Windows/namespace/\(pathSegment(namespace))"
            + "/catalogItem/\(pathSegment(catalogItemId))"
        if let appName, !appName.isEmpty { path += "/app/\(pathSegment(appName))" }
        path += "/label/Live"
        components.path = path
        return components.url
    }

    private static func v1AssetsURL() -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = launcherHost
        components.path = "/launcher/api/public/assets/Windows"
        components.queryItems = [URLQueryItem(name: "label", value: "Live")]
        return components.url
    }

    private static func manifestRef(_ element: AssetElement) -> AssetElement.ManifestRef? {
        guard !element.manifests.isEmpty else { return nil }
        return element.manifests.first { $0.uri.lowercased().hasSuffix(".manifest") } ?? element.manifests.first
    }

    /// The manifest URL exactly as Legendary builds it: `uri` + "?" + the
    /// query params joined verbatim (core.py get_cdn_urls). The values are
    /// already signed; percent-encoding them here would break the signature.
    private static func manifestURL(_ ref: AssetElement.ManifestRef) -> URL? {
        EpicProtocol.requestURL(uri: ref.uri,
                                queryParams: ref.queryParams.map { (name: $0.name, value: $0.value) })
    }

    private static func pathSegment(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private static func send(_ request: URLRequest, authScoped: Bool = true) async throws -> Data {
        var request = request
        request.timeoutInterval = 30
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status < 400 else {
            // A service refusing one call — even with 401/403 — is NOT proof
            // the sign-in is dead: Epic scopes some endpoints to specific
            // clients, and treating that as "expired" signed the owner out
            // seconds after a fresh sign-in (device report, 2026-10-17).
            // Only a refused refresh grant (`EpicAuth.refresh`) signs out;
            // here the caller gets the status and shows it.
            if authScoped, status == 401 || status == 403 {
                throw EpicAuthError.http(status: status, message: "Epic's service refused this session (HTTP \(status)).")
            }
            throw EpicAuthError.http(status: status, message: "Epic's service answered with HTTP \(status).")
        }
        return data
    }
}
