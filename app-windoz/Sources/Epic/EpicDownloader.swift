// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 125hz
// Windoz Converter Exception: see LICENSE-EXCEPTION.md
//
// Phase 6 — the app-side half of Epic's chunked installer. The protocol itself
// (binary build manifest, chunk containers, CDN path scheme, the download loop
// with pause / resume / cancel and its redacted staged log) lives in
// EpicProtocol.swift, which is Foundation + CryptoKit + zlib only so CI can
// compile and exercise it off-device (tests/host, mocked HTTP). This file is
// the adapter: the URLSession transport, the app's storage folder, the app log.
//
// Two device bugs (owner report, 2026-10-18: "Epic downloads fail instantly")
// were root-caused against Legendary and fixed in the protocol:
//  1. The chunk base URL was derived from the manifest URL *with its signed
//     query string*. Foundation's deletingLastPathComponent keeps the query,
//     so every chunk address became `…/guid/?token=…/ChunksV4/…` — a request
//     for the CDN directory — and the first chunk answered 404 within a
//     second. Legendary: base = the manifest URI minus its last path part,
//     query gone (core.py get_cdn_urls `manifest['uri'].rpartition('/')[0]`).
//  2. The manifest and chunk fetches carried `Authorization: bearer …`.
//     Legendary fetches both with unauthenticated sessions — the signed query
//     string is the authorization (core.py get_cdn_manifest uses
//     unauth_session; downloader workers build a fresh session with only a
//     user agent). A header a CDN edge does not expect is one 403 waiting to
//     happen, so it is gone; the launcher API call keeps its bearer.

import Foundation

enum EpicDownloader {

    typealias Progress = EpicProtocol.Progress
    typealias Result = EpicProtocol.Result
    typealias Failure = EpicProtocol.Failure
    typealias InstallControl = EpicProtocol.InstallControl

    // MARK: - The network

    /// URLSession with the launcher's user agent and nothing else — no
    /// Authorization header, exactly like Legendary's CDN fetches.
    struct URLSessionTransport: EpicProtocol.Transport {
        func get(_ url: URL, timeout: TimeInterval) async throws -> (body: Data, status: Int) {
            var request = URLRequest(url: url)
            request.timeoutInterval = timeout
            request.setValue(EpicProtocol.agentString, forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            return (data, status)
        }
    }

    // MARK: - The install

    /// Downloads the build `manifestURL` points at into
    /// <storage root>/EpicGames/<folderName>, logging every stage through the
    /// app log (redacted: no query values, no tokens, no credentials) and
    /// reporting progress. `control` is the UI's pause/resume/cancel handle.
    static func install(manifestURL: URL, expectedManifestSHA1: String?, folderName: String,
                        control: EpicProtocol.InstallControl? = nil,
                        options: EpicProtocol.Options = EpicProtocol.Options(),
                        progress: @escaping (EpicProtocol.Progress) async -> Void) async throws -> EpicProtocol.Result {
        let folder = try installFolder(named: folderName)
        return try await EpicProtocol.install(
            manifestURL: manifestURL,
            expectedManifestSHA1: expectedManifestSHA1,
            folder: folder,
            transport: URLSessionTransport(),
            control: control,
            options: options,
            log: { EpicLog.event("[epic-dl] " + $0) },
            progress: progress)
    }

    // MARK: - Install layout

    static func installFolder(named folderName: String) throws -> URL {
        let base = AppContainer.storageRoot.appendingPathComponent("EpicGames", isDirectory: true)
        var name = folderName
        if !EpicProtocol.validRelativePath(name) { name = "Epic game" }
        let folder = base.appendingPathComponent(name, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            throw Failure.message("Windoz could not create the install folder at \(folder.path): \(error.localizedDescription). \(AppContainer.freeSpaceDescription(at: base))")
        }
        return folder
    }

    /// A filesystem-safe folder name for a game title (Windows-invalid
    /// characters removed, length bounded, never "" or ".").
    static func folderName(for title: String) -> String {
        let banned: Set<Unicode.Scalar> = ["/", "\\", ":", "?", "*", "\"", "<", ">", "|"]
        var name = ""
        for scalar in title.unicodeScalars where scalar.value >= 32 && !banned.contains(scalar) {
            name.unicodeScalars.append(scalar)
        }
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.count > 80 { name = String(name.prefix(80)).trimmingCharacters(in: .whitespaces) }
        if name.isEmpty || name == "." || name == ".." { name = "Epic game" }
        if name.hasSuffix(".") { name += "_" }
        return name
    }
}
