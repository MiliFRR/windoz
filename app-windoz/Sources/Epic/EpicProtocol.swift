// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 125hz
// Windoz Converter Exception: see LICENSE-EXCEPTION.md
//
// Phase 6 — Epic's download protocol, extracted so it can be exercised
// off-device. Everything here is Foundation + CryptoKit + zlib only and takes
// its HTTP through the injected `Transport`, which is what `tests/host` mocks
// in CI. The app's `EpicDownloader` is the thin adapter (URLSession transport,
// app storage paths, the app log).
//
// Ported from Legendary (github.com/legendary-gl/legendary, GPL-3.0): the
// binary build-manifest layout (legendary/models/manifest.py), the chunk
// container (legendary/models/chunk.py), the CDN path scheme
// (ChunkInfo.path - {ChunksVx}/{group}/{hash}_{guid}.chunk, ChunksV5 with
// base64url parts), the URL construction (core.py get_cdn_urls: the chunk base
// is the manifest URI with the last path part removed; query params are joined
// onto the manifest URL verbatim) and the manifest fetch (core.py
// get_cdn_manifest: unauthenticated, the signed query string is the
// authorization; the raw bytes are checked against the hash the launcher
// service returned). Windoz thanks Legendary's authors.
//
// Honesty contract kept from 0.4.0 and extended:
//  - The manifest itself is verified twice: the API's hash over the raw bytes,
//    and the binary header's own SHA-1 over the decompressed body.
//  - Every chunk is decompressed and its SHA-1 compared with the manifest.
//  - Whole files with a manifest hash are verified after assembly.
//  - Encrypted manifests and chunks are refused with a named reason
//    (Failure.encrypted); no DRM is touched.
//  - A file is removed again if it cannot be written or verified
//    (no half-file is ever left behind silently).
//  - Pause/resume/cancel take effect between chunks and files through
//    `InstallControl`; the log says exactly which stage failed and why.

import Foundation
import CryptoKit
import zlib

enum EpicProtocol {

    /// The launcher's own user agent for CDN fetches — Epic's CDN answers the
    /// same way with or without it, but Legendary sends one and so do we.
    static let agentString = "EpicGamesLauncher/14.0.8-22004686+++Portal+Release-Live Windows/10.0.19041.1.256.64bit"

    // MARK: - Errors

    enum Failure: LocalizedError {
        /// A refusal with a sentence the owner can read.
        case message(String)
        /// A refusal by design: Epic's content is encrypted.
        case encrypted(String)
        /// The user cancelled; partial work of the current file is removed.
        case cancelled

        var errorDescription: String? {
            switch self {
            case .message(let text): return text
            case .encrypted(let text): return text
            case .cancelled: return "The download was cancelled. Files that were already finished were kept; the file that was in progress was removed."
            }
        }
    }

    /// A chunk that may succeed at another address or on another attempt.
    struct ChunkRetry: Error { let reason: String }

    // MARK: - Transport

    /// What the protocol needs from the network. The app uses URLSession; the
    /// host tests use a scripted mock. Deliberately tiny: one GET, no auth
    /// header — Epic's signed query strings are the authorization, exactly as
    /// in Legendary's unauthenticated manifest/chunk sessions.
    protocol Transport: Sendable {
        func get(_ url: URL, timeout: TimeInterval) async throws -> (body: Data, status: Int)
    }

    // MARK: - Install control (pause / resume / cancel)

    /// The UI's handle on a running install. `checkpoint()` is called between
    /// chunks and between files: it returns immediately while running, waits
    /// while paused, and throws Failure.cancelled after cancel.
    final class InstallControl: @unchecked Sendable {
        private let lock = NSLock()
        private enum State { case running, paused, cancelled }
        private var state: State = .running
        private var waiters: [CheckedContinuation<Void, Error>] = []

        init() {}

        var isPaused: Bool {
            lock.lock(); defer { lock.unlock() }
            if case .paused = state { return true }
            return false
        }

        var isCancelled: Bool {
            lock.lock(); defer { lock.unlock() }
            if case .cancelled = state { return true }
            return false
        }

        func pause() {
            lock.lock(); defer { lock.unlock() }
            if case .running = state { state = .paused }
        }

        func resume() {
            lock.lock()
            guard case .paused = state else { lock.unlock(); return }
            state = .running
            let waiting = waiters
            waiters.removeAll()
            lock.unlock()
            for waiter in waiting { waiter.resume() }
        }

        func cancel() {
            lock.lock()
            guard case .cancelled = state else {
                state = .cancelled
                let waiting = waiters
                waiters.removeAll()
                lock.unlock()
                for waiter in waiting { waiter.resume(throwing: Failure.cancelled) }
                return
            }
            lock.unlock()
        }

        /// Throws when cancelled, waits while paused, returns while running.
        func checkpoint() async throws {
            lock.lock()
            switch state {
            case .running:
                lock.unlock()
            case .cancelled:
                lock.unlock()
                throw Failure.cancelled
            case .paused:
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    waiters.append(continuation)
                    lock.unlock()
                }
            }
        }
    }

    // MARK: - Options

    struct Options: Sendable {
        /// Delays between attempts for one chunk (so three attempts by default
        /// with 1 s and 2 s waits; the fourth value is the wait before retrying
        /// after a full set fails — again by the user's hand from the UI).
        var retryDelays: [TimeInterval] = [1, 2, 4]
        /// Refuse absurd manifests before allocating.
        var maxManifestBytes = 64 << 20
        var requestTimeout: TimeInterval = 60
        var chunkTimeout: TimeInterval = 120
    }

    // MARK: - Reported types

    struct Progress: Sendable {
        enum Phase: String, Sendable { case manifest, downloading, assembling, done }
        var phase: Phase = .manifest
        var doneBytes: UInt64 = 0
        var totalBytes: UInt64 = 0
        var detail: String = ""
        var fileName: String = ""
    }

    struct Result: Sendable {
        var folder: URL
        var executablePath: String?
        var fileCount: Int
        var bytes: UInt64
        var buildVersion: String
        var skippedSymlinks: Int
    }

    // MARK: - Manifest model

    struct ChunkPart: Sendable {
        let guid: String   // 32 hex characters, the four little-endian words
        let offset: UInt32 // offset within the decompressed chunk
        let size: UInt32   // bytes this part contributes to the file
    }

    struct FileEntry: Sendable {
        let path: String   // install-relative, "/" separated, validated
        let sha1: String?  // whole-file SHA-1 from the manifest, lowercase hex
        let executable: Bool
        let parts: [ChunkPart]
        let size: UInt64
    }

    struct ChunkInfo: Sendable {
        let key: String
        let sha1: String
        let storedSize: UInt64   // bytes this chunk costs on the wire
        let windowSize: UInt32   // bytes the chunk expands to (0 = unknown)
        let chunkPath: String    // path under the CDN base URL
    }

    struct Manifest: Sendable {
        var appName = ""
        var buildVersion = ""
        var launchExecutable = ""
        var launchCommand = ""
        var featureLevel = 18
        var skippedSymlinks = 0
        var files: [FileEntry] = []
        var chunks: [String: ChunkInfo] = [:]
    }

    // MARK: - URL construction (legendary core.py get_cdn_urls)

    /// The manifest URL: the API's `uri` with its `queryParams` joined on
    /// verbatim — no re-encoding, byte for byte like Legendary, because the
    /// values are already signed and re-encoding them breaks the signature.
    static func requestURL(uri: String, queryParams: [(name: String, value: String)]) -> URL? {
        var text = uri
        if !queryParams.isEmpty {
            let joined = queryParams.map { "\($0.name)=\($0.value)" }.joined(separator: "&")
            text += "?" + joined
        }
        return URL(string: text)
    }

    /// The chunk base URL: the manifest URI's parent, **without** any query
    /// string. Legendary: `manifest['uri'].rpartition('/')[0]` — the query
    /// string belongs to the manifest fetch only and must never end up in a
    /// chunk URL (0.4.x device bug: it did, and every chunk URL became a
    /// directory request answered with 404).
    static func baseURL(fromManifestURL url: URL) -> String {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.query = nil
        components?.fragment = nil
        var path = components?.path ?? url.path
        while path.hasSuffix("/") && path.count > 1 { path.removeLast() }
        let parent = (path as NSString).deletingLastPathComponent
        components?.path = parent.isEmpty ? "/" : parent
        var text = components?.string ?? url.absoluteString
        while text.hasSuffix("/") && text.count > 1 { text.removeLast() }
        return text
    }

    /// A URL safe to put in a log: query values redacted, never a token.
    static func redactedURL(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return "(unparseable URL)" }
        let count = components.queryItems?.count ?? 0
        components.query = nil
        var text = components.string ?? "(unparseable URL)"
        if count > 0 { text += "?<\(count) params redacted>" }
        return text
    }

    // MARK: - Assets response (launcher-public-service)

    /// One `elements` entry of the assets response (legendary's api/egs.py:
    /// get_game_manifest / get_game_assets), including the launcher service's
    /// SHA-1 for the manifest bytes.
    struct AssetElement: Sendable {
        struct ManifestRef: Sendable {
            struct QueryParam: Sendable { let name: String; let value: String }
            let uri: String
            let queryParams: [QueryParam]
        }
        let appName: String?
        let labelName: String?
        let buildVersion: String?
        let namespace: String?
        let catalogItemId: String?
        let hash: String?
        let manifests: [ManifestRef]
    }

    /// Deliberately lenient (Phase 6): Epic's services add fields without
    /// notice, and a strict decode used to drop the entire list when anything
    /// was unexpected — the UI then said "Epic has no live Windows build",
    /// which was not true. Unknown fields are ignored; `elements` may be
    /// wrapped or a bare list; a missing field costs that field, never the
    /// response. Exercised by tests/host.
    static func parseAssetElements(_ data: Data) -> [AssetElement] {
        guard let root = try? JSONSerialization.jsonObject(with: data) else { return [] }
        let rawElements: [Any]
        if let object = root as? [String: Any], let elements = object["elements"] as? [Any] {
            rawElements = elements
        } else if let list = root as? [Any] {
            rawElements = list
        } else {
            return []
        }
        return rawElements.compactMap { raw in
            guard let object = raw as? [String: Any] else { return nil }
            let refs = (object["manifests"] as? [Any] ?? []).compactMap { rawManifest -> AssetElement.ManifestRef? in
                guard let manifest = rawManifest as? [String: Any],
                      let uri = manifest["uri"] as? String, !uri.isEmpty else { return nil }
                let params = (manifest["queryParams"] as? [Any] ?? []).compactMap { rawParam -> AssetElement.ManifestRef.QueryParam? in
                    guard let param = rawParam as? [String: Any],
                          let name = param["name"] as? String,
                          let value = param["value"] as? String else { return nil }
                    return AssetElement.ManifestRef.QueryParam(name: name, value: value)
                }
                return AssetElement.ManifestRef(uri: uri, queryParams: params)
            }
            return AssetElement(appName: object["appName"] as? String,
                                labelName: object["labelName"] as? String,
                                buildVersion: object["buildVersion"] as? String,
                                namespace: object["namespace"] as? String,
                                catalogItemId: object["catalogItemId"] as? String,
                                hash: object["hash"] as? String,
                                manifests: refs)
        }
    }

    // MARK: - Chunk paths (legendary models/manifest.py, ChunkInfo.path)

    static func chunkPath(guid: (UInt32, UInt32, UInt32, UInt32), hash: UInt64, featureLevel: Int) -> String {
        let directory: String
        if featureLevel >= 22 { directory = "ChunksV5" }
        else if featureLevel >= 15 { directory = "ChunksV4" }
        else if featureLevel >= 6 { directory = "ChunksV3" }
        else if featureLevel >= 3 { directory = "ChunksV2" }
        else { directory = "Chunks" }
        let group = groupNumber(guid)
        if featureLevel >= 22 {
            // "plain" — encrypted chunks (a non-zero secret GUID) are refused
            // before a path is ever needed for them.
            return String(format: "%@/plain/%02d/%@_%@.chunk", directory, group,
                          base64URL(packU64(hash)), base64URL(packGUID(guid)))
        }
        return String(format: "%@/%02d/%016llX_%08X%08X%08X%08X.chunk", directory, group, hash,
                      guid.0, guid.1, guid.2, guid.3)
    }

    static func groupNumber(_ guid: (UInt32, UInt32, UInt32, UInt32)) -> Int {
        let bytes = packGUID(guid)
        let value: UInt32 = bytes.withUnsafeBytes { buffer in
            UInt32(crc32(0, buffer.bindMemory(to: UInt8.self).baseAddress, uInt(bytes.count)))
        }
        return Int(value) % 100
    }

    static func guidKey(_ guid: (UInt32, UInt32, UInt32, UInt32)) -> String {
        String(format: "%08X%08X%08X%08X", guid.0, guid.1, guid.2, guid.3)
    }

    static func guidKey(_ bytes: Data) -> String {
        guard bytes.count >= 16 else { return "" }
        func word(_ offset: Int) -> UInt32 {
            let base = bytes.startIndex + offset
            return UInt32(bytes[base]) | UInt32(bytes[base + 1]) << 8
                | UInt32(bytes[base + 2]) << 16 | UInt32(bytes[base + 3]) << 24
        }
        return String(format: "%08X%08X%08X%08X", word(0), word(4), word(8), word(12))
    }

    static func packGUID(_ guid: (UInt32, UInt32, UInt32, UInt32)) -> Data {
        var data = Data(capacity: 16)
        for value in [guid.0, guid.1, guid.2, guid.3] {
            for shift in stride(from: 0, through: 24, by: 8) {
                data.append(UInt8(truncatingIfNeeded: value >> UInt32(shift)))
            }
        }
        return data
    }

    static func packU64(_ value: UInt64) -> Data {
        var data = Data(capacity: 8)
        for shift in stride(from: 0, through: 56, by: 8) {
            data.append(UInt8(truncatingIfNeeded: value >> UInt64(shift)))
        }
        return data
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: - File paths

    /// No empty components, ".", "..", drive letters, control characters or
    /// names Windows cannot create.
    static func validRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, path.utf8.count <= 1024 else { return false }
        guard !path.contains(":") else { return false }
        guard !path.unicodeScalars.contains(where: { $0.value < 32 }) else { return false }
        for component in path.split(separator: "/", omittingEmptySubsequences: false) {
            if component.isEmpty || component == "." || component == ".." { return false }
            if component.hasSuffix(".") || component.hasSuffix(" ") { return false }
        }
        return true
    }

    // MARK: - Hashing

    static func sha1Hex(_ data: Data) -> String {
        Insecure.SHA1.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Lowercase hex, e.g. for the digests Epic's manifest carries.
    static func hexStringOf(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    static func sha1HexOfFile(_ url: URL) throws -> String {
        var hasher = Insecure.SHA1()
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw Failure.message("Verifying '\(url.lastPathComponent)' failed: \(error.localizedDescription)")
        }
        defer { try? handle.close() }
        while true {
            let block = (try? handle.read(upToCount: 1 << 20)) ?? Data()
            if block.isEmpty { break }
            hasher.update(data: block)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Manifest parsing

    /// The manifest. `expectedSHA1` is the launcher service's own hash of the
    /// raw bytes (Legendary checks it in core.py get_cdn_manifest); the binary
    /// header then carries a second, inner hash over the decompressed body.
    static func parseManifest(_ data: Data, expectedSHA1: String? = nil, log: (String) -> Void = { _ in }) throws -> Manifest {
        if let expectedSHA1, !expectedSHA1.isEmpty {
            let actual = sha1Hex(data)
            guard actual.caseInsensitiveCompare(expectedSHA1) == .orderedSame else {
                throw Failure.message("Epic's build manifest did not match the hash the launcher service gave (downloaded \(actual.prefix(12))…, expected \(expectedSHA1.prefix(12))…); refusing it.")
            }
        }
        guard data.count >= 16 else { throw Failure.message("Epic's build manifest is empty or truncated.") }
        guard data.u32LE(0) == 0x44BEC00C else {
            if data.first == UInt8(ascii: "{") {
                throw Failure.message("This title's build uses Epic's legacy JSON manifest format, which this build does not install yet. Modern Windows builds use the binary format; this title needs a later Windoz.")
            }
            throw Failure.message("Epic's build manifest is not in the format this build understands.")
        }
        var cursor = Cursor(data: data)
        _ = try cursor.u32() // header magic
        let headerSize = Int(try cursor.u32())
        let declaredUncompressed = Int(try cursor.u32())
        _ = try cursor.u32() // compressed size
        let manifestSHA = try cursor.bytes(20)
        let storedAs = try cursor.byte()
        let version = Int(try cursor.u32())
        if version >= 22 {
            let secret = try cursor.bytes(16)
            _ = try cursor.bytes(16) // encryption tag
            if secret.contains(where: { $0 != 0 }) {
                throw Failure.encrypted("This build's manifest is encrypted by Epic (v\(version)). Windoz does not touch encrypted content: this title cannot be installed yet.")
            }
        }
        guard headerSize >= cursor.index, headerSize <= data.count else {
            throw Failure.message("Epic's build manifest header is inconsistent; refusing it.")
        }
        cursor.index = headerSize
        var body = try cursor.bytes(cursor.remaining)
        if storedAs & 0x1 != 0 {
            let hint = declaredUncompressed > 0 && declaredUncompressed <= 256 << 20 ? declaredUncompressed : nil
            guard let inflated = inflateData(body, hint: hint, cap: 256 << 20) else {
                throw Failure.message("Epic's build manifest did not decompress.")
            }
            guard Data(Insecure.SHA1.hash(data: inflated)) == manifestSHA else {
                throw Failure.message("Epic's build manifest failed its own SHA-1 check; refusing it.")
            }
            body = inflated
        }
        let manifest = try parseBody(body)
        log("manifest ok: version=\(version) feature=\(manifest.featureLevel) chunks=\(manifest.chunks.count) files=\(manifest.files.count) (body \(body.count) bytes)")
        return manifest
    }

    private static func parseBody(_ body: Data) throws -> Manifest {
        var cursor = Cursor(data: body)
        var manifest = Manifest()

        // ManifestMeta (legendary/models/manifest.py, ManifestMeta.read).
        let metaStart = cursor.index
        let metaSize = Int(try cursor.u32())
        let dataVersion = try cursor.byte()
        manifest.featureLevel = Int(try cursor.u32())
        _ = try cursor.byte() // is-file-data, unused by modern apps
        _ = try cursor.u32()  // app id, generally 0
        manifest.appName = try cursor.fstring()
        manifest.buildVersion = try cursor.fstring()
        manifest.launchExecutable = try cursor.fstring()
        manifest.launchCommand = try cursor.fstring()
        let prereqCount = Int(try cursor.u32())
        guard prereqCount >= 0, prereqCount <= 64 else { throw inconsistent() }
        for _ in 0..<prereqCount { _ = try cursor.fstring() }
        _ = try cursor.fstring() // prerequisite name
        _ = try cursor.fstring() // prerequisite path
        _ = try cursor.fstring() // prerequisite arguments
        if dataVersion >= 1 { _ = try cursor.fstring() } // build id
        if dataVersion >= 2 { _ = try cursor.fstring(); _ = try cursor.fstring() } // uninstall command
        try cursor.move(to: metaStart + metaSize, limit: body.count)

        // Chunk data list.
        let cdlStart = cursor.index
        let cdlSize = Int(try cursor.u32())
        _ = try cursor.byte() // list version
        let chunkCount = Int(try cursor.u32())
        guard chunkCount >= 0, chunkCount <= 1_000_000 else { throw inconsistent() }
        var guids: [(UInt32, UInt32, UInt32, UInt32)] = []
        guids.reserveCapacity(chunkCount)
        for _ in 0..<chunkCount {
            guids.append((try cursor.u32(), try cursor.u32(), try cursor.u32(), try cursor.u32()))
        }
        var hashes: [UInt64] = []
        hashes.reserveCapacity(chunkCount)
        for _ in 0..<chunkCount { hashes.append(try cursor.u64()) }
        var shas: [String] = []
        shas.reserveCapacity(chunkCount)
        for _ in 0..<chunkCount { shas.append(hexStringOf(try cursor.bytes(20))) }
        try cursor.skip(chunkCount) // group numbers (recomputed from the GUID)
        var windows: [UInt32] = []
        windows.reserveCapacity(chunkCount)
        for _ in 0..<chunkCount { windows.append(try cursor.u32()) }
        var storedSizes: [UInt64] = []
        storedSizes.reserveCapacity(chunkCount)
        for _ in 0..<chunkCount { storedSizes.append(try cursor.u64()) }
        if manifest.featureLevel >= 22 {
            for _ in 0..<chunkCount {
                let secret = try cursor.bytes(16)
                if secret.contains(where: { $0 != 0 }) {
                    throw Failure.encrypted("This build's chunks are encrypted by Epic. Windoz does not touch encrypted content: this title cannot be installed yet.")
                }
            }
            try cursor.skip(chunkCount * 4)  // compressed window sizes
            try cursor.skip(chunkCount * 16) // encryption tags
        }
        try cursor.move(to: cdlStart + cdlSize, limit: body.count)
        for index in 0..<chunkCount {
            let key = guidKey(guids[index])
            manifest.chunks[key] = ChunkInfo(key: key, sha1: shas[index], storedSize: storedSizes[index],
                                             windowSize: windows[index],
                                             chunkPath: chunkPath(guid: guids[index], hash: hashes[index],
                                                                  featureLevel: manifest.featureLevel))
        }

        // File manifest list.
        let fmlStart = cursor.index
        let fmlSize = Int(try cursor.u32())
        let fmlVersion = Int(try cursor.byte())
        let fileCount = Int(try cursor.u32())
        guard fileCount >= 0, fileCount <= 200_000 else { throw inconsistent() }
        var names: [String] = []
        names.reserveCapacity(fileCount)
        for _ in 0..<fileCount { names.append(try cursor.fstring()) }
        var symlinks: [String] = []
        symlinks.reserveCapacity(fileCount)
        for _ in 0..<fileCount { symlinks.append(try cursor.fstring()) }
        var fileHashes: [String?] = []
        fileHashes.reserveCapacity(fileCount)
        for _ in 0..<fileCount {
            let raw = try cursor.bytes(20)
            fileHashes.append(raw.contains(where: { $0 != 0 }) ? hexStringOf(raw) : nil)
        }
        var flags: [UInt8] = []
        flags.reserveCapacity(fileCount)
        for _ in 0..<fileCount { flags.append(try cursor.byte()) }
        for _ in 0..<fileCount {
            let tagCount = Int(try cursor.u32())
            guard tagCount >= 0, tagCount <= 64 else { throw inconsistent() }
            for _ in 0..<tagCount { _ = try cursor.fstring() }
        }
        var rawParts: [[ChunkPart]] = []
        rawParts.reserveCapacity(fileCount)
        for _ in 0..<fileCount {
            let partCount = Int(try cursor.u32())
            guard partCount >= 0, partCount <= 2_000_000 else { throw inconsistent() }
            var parts: [ChunkPart] = []
            parts.reserveCapacity(partCount)
            for _ in 0..<partCount {
                let recordSize = Int(try cursor.u32())
                let guid = try cursor.bytes(16)
                let offset = try cursor.u32()
                let size = try cursor.u32()
                if recordSize > 28 { try cursor.skip(recordSize - 28) }
                parts.append(ChunkPart(guid: guidKey(guid), offset: offset, size: size))
            }
            rawParts.append(parts)
        }
        if fmlVersion >= 1 {
            for _ in 0..<fileCount {
                let hasMD5 = try cursor.u32()
                if hasMD5 != 0 { try cursor.skip(16) }
            }
            for _ in 0..<fileCount { _ = try cursor.fstring() } // MIME types
        }
        if fmlVersion >= 2 { try cursor.skip(fileCount * 32) } // SHA-256 per file
        try cursor.move(to: fmlStart + fmlSize, limit: body.count)

        var seen = Set<String>()
        var files: [FileEntry] = []
        files.reserveCapacity(fileCount)
        for index in 0..<fileCount {
            if !symlinks[index].isEmpty {
                manifest.skippedSymlinks += 1
                continue
            }
            var path = names[index].replacingOccurrences(of: "\\", with: "/")
            while path.hasPrefix("/") { path.removeFirst() }
            guard validRelativePath(path) else {
                throw Failure.message("Epic's build manifest names a file Windoz will not write ('\(String(path.prefix(80)))').")
            }
            guard seen.insert(path.lowercased()).inserted else {
                throw Failure.message("Epic's build manifest lists two files that differ only by letter case; Windoz's file system cannot hold both. This title cannot be installed yet.")
            }
            let parts = rawParts[index]
            let size = parts.reduce(UInt64(0)) { $0 + UInt64($1.size) }
            files.append(FileEntry(path: path, sha1: fileHashes[index],
                                   executable: flags[index] & 0x4 != 0, parts: parts, size: size))
        }
        manifest.files = files
        return manifest
    }

    private static func inconsistent() -> Failure {
        .message("Epic's build manifest is inconsistent; refusing it.")
    }

    // MARK: - Chunk decoding

    /// The chunk container (legendary/models/chunk.py): magic 0xB1FE3AA2, a
    /// header, then the payload. The payload may be zlib-compressed; the
    /// decompressed bytes must match the manifest's SHA-1 for this chunk.
    static func decodeChunk(_ raw: Data, info: ChunkInfo) throws -> Data {
        guard raw.count >= 48, raw.u32LE(0) == 0xB1FE3AA2 else {
            throw ChunkRetry(reason: "not a chunk container")
        }
        let headerVersion = raw.u32LE(4) ?? 0
        let headerSize = Int(raw.u32LE(8) ?? 0)
        guard headerSize >= 40, headerSize <= raw.count else {
            throw ChunkRetry(reason: "chunk header is out of range")
        }
        let storedAs = raw.byte(at: 40) ?? 0
        guard storedAs & 0x2 == 0 else {
            throw Failure.encrypted("This build's chunks are encrypted by Epic. Windoz does not touch encrypted content: this title cannot be installed yet.")
        }
        let headerSHA: String? = headerVersion >= 2 ? raw.hex(41, 20) : nil
        let expected = Int(info.windowSize)

        let payload = raw.subdata(in: headerSize..<raw.count)
        var candidates: [Data] = []
        if storedAs & 0x1 != 0 {
            if let inflated = inflateData(payload, hint: expected > 0 ? expected : nil) { candidates.append(inflated) }
            candidates.append(payload) // some CDN edges have served already-inflated bytes
        } else {
            candidates.append(payload)
        }
        for candidate in candidates {
            // The SHA-1 is authoritative: accept exactly the bytes the
            // manifest vouches for, nothing else. (The length may legitimately
            // differ from window_size, which is a buffer size.)
            let digest = sha1Hex(candidate)
            if digest == info.sha1 || (headerSHA != nil && digest == headerSHA) {
                return candidate
            }
        }
        throw ChunkRetry(reason: "chunk digest did not match the manifest")
    }

    // MARK: - The install

    /// Downloads the build `manifestURL` points at and writes every file into
    /// `folder`. Throws a named reason for every refusal; never leaves a
    /// partially-written file behind; `control` pauses between chunks and
    /// files; `log` gets redacted, stage-tagged lines.
    static func install(manifestURL: URL, expectedManifestSHA1: String? = nil,
                        folder: URL, transport: Transport, control: InstallControl? = nil,
                        options: Options = Options(),
                        log: @escaping (String) -> Void = { _ in },
                        progress: @escaping (Progress) async -> Void) async throws -> Result {
        let base = baseURL(fromManifestURL: manifestURL)
        await progress(Progress(phase: .manifest, detail: "Asking Epic for the build manifest"))
        log("manifest GET \(redactedURL(manifestURL))")
        let manifestResponse: (body: Data, status: Int)
        do {
            manifestResponse = try await transport.get(manifestURL, timeout: options.requestTimeout)
        } catch let failure as Failure {
            throw failure
        } catch {
            log("manifest GET failed: \(error.localizedDescription)")
            throw Failure.message("Epic's manifest service could not be reached (\(error.localizedDescription)). Check the connection and try again.")
        }
        let manifestData = manifestResponse.body
        let status = manifestResponse.status
        guard status == 200 else {
            log("manifest HTTP \(status)")
            throw Failure.message("Epic's manifest service answered with HTTP \(status). The download link may have expired — start the download again to get a fresh one.")
        }
        guard manifestData.count <= options.maxManifestBytes else {
            throw Failure.message("Epic's build manifest is unexpectedly large; refusing it.")
        }
        log("manifest HTTP 200, \(manifestData.count) bytes")
        let manifest = try parseManifest(manifestData, expectedSHA1: expectedManifestSHA1, log: log)
        guard !manifest.files.isEmpty else {
            throw Failure.message("Epic's build manifest lists no files; refusing to install nothing.")
        }

        let totalFiles = manifest.files.count
        let installSize = manifest.files.reduce(UInt64(0)) { $0 + $1.size }
        try await control?.checkpoint()

        // How many times each chunk is needed. A chunk is dropped from memory
        // the moment its last reference has been written to disk.
        var references: [String: Int] = [:]
        for file in manifest.files {
            for part in file.parts { references[part.guid, default: 0] += 1 }
        }
        var totalStored: UInt64 = 0
        for (key, count) in references where count > 0 {
            if let info = manifest.chunks[key] { totalStored += info.storedSize }
        }

        log("install: base \(base) — \(totalFiles) files, \(ByteCountFormatter.string(fromByteCount: Int64(clamping: installSize), countStyle: .file)) installed size, \(manifest.chunks.count) chunks")
        await progress(Progress(phase: .downloading, doneBytes: 0, totalBytes: totalStored,
                                detail: "\(totalFiles) files, \(ByteCountFormatter.string(fromByteCount: Int64(clamping: installSize), countStyle: .file)) installed size"))

        var doneStored: UInt64 = 0
        var cache: [String: Data] = [:]
        var writtenFiles = 0
        var writtenBytes: UInt64 = 0
        var chunksFetched = 0
        var filesSkipped = 0

        for file in manifest.files {
            try await control?.checkpoint()
            let destination = folder.appendingPathComponent(file.path)
            do {
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
            } catch {
                throw Failure.message("Windoz could not create a folder for '\(file.path)': \(error.localizedDescription)")
            }

            // A finished file from an earlier run whose hash still matches is
            // kept: cancel and restart does not download the same bytes twice.
            if let expected = file.sha1, FileManager.default.fileExists(atPath: destination.path),
               let actual = try? sha1HexOfFile(destination), actual == expected {
                filesSkipped += 1
                writtenFiles += 1
                writtenBytes += file.size
                releaseReferences(file.parts, references: &references, cache: &cache)
                // Credit the skipped bytes once so a resumed run's progress can
                // still reach 100% — these chunks were already on disk.
                var credited = Set<String>()
                for part in file.parts where credited.insert(part.guid).inserted {
                    if cache[part.guid] == nil, (references[part.guid] ?? 1) <= 0,
                       let info = manifest.chunks[part.guid] {
                        doneStored += info.storedSize
                    }
                }
                log("file '\(file.path)' already present and verified — kept (\(filesSkipped) kept so far)")
                await progress(Progress(phase: .downloading, doneBytes: doneStored, totalBytes: totalStored,
                                        detail: "\(writtenFiles)/\(totalFiles) files",
                                        fileName: file.path))
                continue
            }

            // Fetch every chunk this file needs that is not already in memory.
            var needed: [String] = []
            var seenParts = Set<String>()
            for part in file.parts where seenParts.insert(part.guid).inserted {
                if cache[part.guid] == nil { needed.append(part.guid) }
            }
            for key in needed {
                try await control?.checkpoint()
                guard let info = manifest.chunks[key] else {
                    throw Failure.message("Epic's build manifest references a chunk it does not describe (\(key)); refusing the install.")
                }
                let data = try await downloadChunk(key: key, info: info, base: base,
                                                   transport: transport, options: options,
                                                   control: control, log: log)
                if cache[key] == nil {
                    cache[key] = data
                    doneStored += info.storedSize
                }
                chunksFetched += 1
                if chunksFetched % 25 == 0 {
                    log("chunk progress: \(chunksFetched) fetched, \(doneStored) of \(totalStored) stored bytes")
                }
            }

            // Write the file: its chunk parts, in order, at their offsets.
            // Any failure removes the file again — never a silent half-file.
            do {
                try? FileManager.default.removeItem(at: destination)
                guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
                    throw Failure.message("Windoz could not create '\(file.path)'.")
                }
                let handle = try FileHandle(forWritingTo: destination)
                do {
                    for part in file.parts {
                        guard let chunk = cache[part.guid] else {
                            throw Failure.message("Epic's build manifest references a chunk it does not describe (\(part.guid)); refusing the install.")
                        }
                        let start = Int(part.offset)
                        let end = start + Int(part.size)
                        guard end <= chunk.count else {
                            throw Failure.message("A chunk for '\(file.path)' is shorter than the manifest says; refusing the install.")
                        }
                        try handle.write(contentsOf: chunk.subdata(in: start..<end))
                    }
                    try handle.close()
                } catch {
                    try? handle.close()
                    throw error
                }
                if let expected = file.sha1 {
                    let actual = try sha1HexOfFile(destination)
                    guard actual == expected else {
                        throw Failure.message("'\(file.path)' did not match the hash Epic's manifest carries (downloaded \(actual.prefix(12))…, expected \(expected.prefix(12))…). The download was corrupted; start it again.")
                    }
                }
            } catch {
                try? FileManager.default.removeItem(at: destination)
                log("file '\(file.path)' failed and was removed: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)")
                throw error
            }

            releaseReferences(file.parts, references: &references, cache: &cache)
            writtenFiles += 1
            writtenBytes += file.size
            await progress(Progress(phase: .downloading, doneBytes: doneStored, totalBytes: totalStored,
                                    detail: "\(writtenFiles)/\(totalFiles) files",
                                    fileName: file.path))
        }

        await progress(Progress(phase: .assembling, doneBytes: doneStored, totalBytes: totalStored,
                                detail: "Locating the game's program"))
        let executable = resolveExecutable(manifest, folder: folder)
        await progress(Progress(phase: .done, doneBytes: doneStored, totalBytes: totalStored,
                                detail: "\(writtenFiles) files, \(ByteCountFormatter.string(fromByteCount: Int64(clamping: writtenBytes), countStyle: .file)) written"))
        log("install done: written=\(writtenFiles) skipped-files=\(filesSkipped) bytes=\(writtenBytes) exe=\(executable == nil ? 0 : 1) skipped-symlinks=\(manifest.skippedSymlinks)")
        return Result(folder: folder, executablePath: executable, fileCount: writtenFiles,
                      bytes: writtenBytes, buildVersion: manifest.buildVersion,
                      skippedSymlinks: manifest.skippedSymlinks)
    }

    private static func releaseReferences(_ parts: [ChunkPart], references: inout [String: Int],
                                          cache: inout [String: Data]) {
        for part in parts {
            guard let remaining = references[part.guid] else { continue }
            let left = remaining - 1
            references[part.guid] = left
            if left <= 0 { cache.removeValue(forKey: part.guid) }
        }
    }

    // MARK: - One chunk (retries with backoff)

    /// One chunk, with bounded retries and named refusals. 403/404 abort at
    /// once — a signed URL that expired or a wrong path will not fix itself.
    static func downloadChunk(key: String, info: ChunkInfo, base: String,
                              transport: Transport, options: Options,
                              control: InstallControl?, log: (String) -> Void) async throws -> Data {
        let address = "\(base)/\(info.chunkPath)"
        guard let url = URL(string: address) else {
            throw Failure.message("Epic gave a chunk address Windoz cannot parse (\(info.chunkPath)).")
        }
        var lastReason = "no attempt was made"
        let attempts = max(1, options.retryDelays.count + 1)
        for attempt in 1...attempts {
            try await control?.checkpoint()
            do {
                let (body, status) = try await transport.get(url, timeout: options.chunkTimeout)
                guard status == 200 else {
                    if status == 403 {
                        throw Failure.message("Epic's CDN refused this chunk (HTTP 403) at \(redactedURL(url)). The download link may have expired — start the download again.")
                    }
                    if status == 404 {
                        throw Failure.message("Epic's CDN does not have this chunk (HTTP 404) at \(redactedURL(url)). The log has the requested path.")
                    }
                    lastReason = "HTTP \(status)"
                    log("chunk \(key) attempt \(attempt)/\(attempts): HTTP \(status)")
                    if attempt < attempts { try await sleep(options.retryDelays[min(attempt - 1, options.retryDelays.count - 1)]) }
                    continue
                }
                do {
                    return try decodeChunk(body, info: info)
                } catch let refusal as Failure {
                    throw refusal
                } catch let retry as ChunkRetry {
                    lastReason = retry.reason
                    log("chunk \(key) attempt \(attempt)/\(attempts): \(retry.reason)")
                }
            } catch let refusal as Failure {
                throw refusal
            } catch let retry as ChunkRetry {
                lastReason = retry.reason
                log("chunk \(key) attempt \(attempt)/\(attempts): \(retry.reason)")
            } catch {
                lastReason = error.localizedDescription
                log("chunk \(key) attempt \(attempt)/\(attempts): \(error.localizedDescription)")
            }
            if attempt < attempts {
                try await sleep(options.retryDelays[min(attempt - 1, options.retryDelays.count - 1)])
            }
        }
        throw Failure.message("Chunk \(key) could not be downloaded (\(lastReason)) after \(attempts) attempt(s).")
    }

    private static func sleep(_ seconds: TimeInterval) async throws {
        let nanoseconds = UInt64(max(0, seconds) * 1_000_000_000)
        if nanoseconds > 0 { try await Task.sleep(nanoseconds: nanoseconds) }
    }

    // MARK: - The game's program

    static func resolveExecutable(_ manifest: Manifest, folder: URL) -> String? {
        var candidates: [String] = []
        if !manifest.launchExecutable.isEmpty { candidates.append(manifest.launchExecutable) }
        if let fromCommand = commandExecutable(manifest.launchCommand) { candidates.append(fromCommand) }
        for candidate in candidates {
            var path = candidate.replacingOccurrences(of: "\\", with: "/")
            while path.hasPrefix("/") { path.removeFirst() }
            guard validRelativePath(path) else { continue }
            let direct = folder.appendingPathComponent(path)
            if FileManager.default.fileExists(atPath: direct.path) { return direct.standardizedFileURL.path }
            // Different case or an added sub-folder: find it by name, bounded.
            let wanted = (path as NSString).lastPathComponent.lowercased()
            if let found = searchForFile(named: wanted, in: folder, depth: 4) { return found }
        }
        return nil
    }

    /// "Game.exe -arg" or "\"Sub Folder/Game.exe\" -arg".
    static func commandExecutable(_ command: String) -> String? {
        var text = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if text.hasPrefix("\"") {
            text.removeFirst()
            guard let end = text.firstIndex(of: "\"") else { return nil }
            return String(text[text.startIndex..<end])
        }
        return text.split(separator: " ").first.map(String.init)
    }

    private static func searchForFile(named lowercasedName: String, in folder: URL, depth: Int) -> String? {
        guard depth > 0 else { return nil }
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey],
                                                      options: [.skipsHiddenFiles]) else { return nil }
        var directories: [URL] = []
        for item in items.prefix(4000) {
            let isDirectory = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDirectory {
                directories.append(item)
            } else if item.lastPathComponent.lowercased() == lowercasedName {
                return item.standardizedFileURL.path
            }
        }
        for directory in directories.prefix(200) {
            if let found = searchForFile(named: lowercasedName, in: directory, depth: depth - 1) { return found }
        }
        return nil
    }

    // MARK: - zlib and binary readers

    /// zlib first (Epic's chunks are zlib streams), then raw deflate as a
    /// fallback. `hint` bounds the output buffer when the expanded size is
    /// known; `cap` raises that limit for build manifests.
    static func inflateData(_ data: Data, hint: Int?, cap limit: Int? = nil) -> Data? {
        let cap = min(max(hint ?? limit ?? max(data.count * 4, 1 << 20), 1024), 256 << 20)
        for windowBits in [Int32(15), Int32(-15)] {
            var stream = z_stream()
            var out = Data(count: cap)
            var produced = -1
            data.withUnsafeBytes { src in
                out.withUnsafeMutableBytes { dst in
                    stream.next_in = UnsafeMutablePointer(mutating: src.bindMemory(to: UInt8.self).baseAddress)
                    stream.avail_in = UInt32(data.count)
                    stream.next_out = dst.bindMemory(to: UInt8.self).baseAddress
                    stream.avail_out = UInt32(cap)
                    guard inflateInit2_(&stream, windowBits, ZLIB_VERSION,
                                         Int32(MemoryLayout<z_stream>.size)) == Z_OK else { return }
                    let result = inflate(&stream, Z_FINISH)
                    inflateEnd(&stream)
                    if result == Z_STREAM_END || (result == Z_OK && Int(stream.total_out) == cap) {
                        produced = Int(stream.total_out)
                    }
                }
            }
            if produced > 0 {
                out.count = produced
                return out
            }
        }
        return nil
    }

    struct Cursor {
        let data: Data
        var index = 0

        var remaining: Int { data.count - index }

        mutating func skip(_ count: Int) throws {
            guard count >= 0, remaining >= count else { throw truncated }
            index += count
        }

        mutating func move(to offset: Int, limit: Int) throws {
            guard offset >= index, offset <= limit else { throw truncated }
            index = offset
        }

        mutating func byte() throws -> UInt8 {
            guard remaining >= 1 else { throw truncated }
            defer { index += 1 }
            return data[data.startIndex + index]
        }

        mutating func u32() throws -> UInt32 {
            guard let value = data.u32LE(index) else { throw truncated }
            index += 4
            return value
        }

        mutating func u64() throws -> UInt64 {
            guard let value = data.u64LE(index) else { throw truncated }
            index += 8
            return value
        }

        mutating func bytes(_ count: Int) throws -> Data {
            guard count >= 0, remaining >= count else { throw truncated }
            let start = data.startIndex + index
            defer { index += count }
            return data.subdata(in: start..<start + count)
        }

        /// Epic's length-prefixed string: negative length = UTF-16, positive =
        /// ASCII with a terminator. (legendary read_fstring.)
        mutating func fstring() throws -> String {
            let rawLength = try u32()
            let length = Int32(bitPattern: rawLength)
            if length == 0 { return "" }
            if length > 0 {
                let raw = try bytes(Int(length) - 1)
                try skip(1)
                return String(decoding: raw, as: UTF8.self)
            }
            guard length > Int32.min else { throw truncated }
            let byteCount = Int(-length) * 2
            guard byteCount >= 2 else { return "" }
            let raw = try bytes(byteCount - 2)
            try skip(2)
            return String(data: raw, encoding: .utf16LittleEndian) ?? ""
        }

        var truncated: Failure {
            .message("Epic's build manifest ended before it said it would — refusing it.")
        }
    }
}

// MARK: - Byte access

extension Data {
    func byte(at offset: Int) -> UInt8? {
        guard offset >= 0, offset < count else { return nil }
        return self[startIndex + offset]
    }

    func u32LE(_ offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= count else { return nil }
        let base = startIndex + offset
        return UInt32(self[base]) | UInt32(self[base + 1]) << 8
            | UInt32(self[base + 2]) << 16 | UInt32(self[base + 3]) << 24
    }

    func u64LE(_ offset: Int) -> UInt64? {
        guard offset >= 0, offset + 8 <= count else { return nil }
        var value: UInt64 = 0
        for index in (0..<8).reversed() { value = value << 8 | UInt64(self[startIndex + offset + index]) }
        return value
    }

    func hex(_ offset: Int, _ length: Int) -> String? {
        guard offset >= 0, offset + length <= count else { return nil }
        let start = startIndex + offset
        return self[start..<start + length].map { String(format: "%02x", $0) }.joined()
    }
}
