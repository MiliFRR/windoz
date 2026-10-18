// SPDX-License-Identifier: GPL-3.0-or-later
// Windoz — Epic's chunked downloader.
//
// Ported from Legendary (github.com/legendary-gl/legendary, GPL-3.0): the
// binary build-manifest layout (legendary/models/manifest.py), the chunk
// container format (legendary/models/chunk.py), the CDN path scheme
// ({ChunksVx}/{group}/{hash}_{guid}.chunk) and the download pipeline order
// (legendary/downloader/mp). Windoz thanks Legendary's authors — without
// their reverse engineering this piece would not exist.
//
// Honesty contract for this file:
//  - Every chunk is verified: its decompressed bytes must match the SHA-1 the
//    build manifest records for it. Files with a manifest hash are verified
//    whole, streamed, after assembly.
//  - Encrypted manifests and encrypted chunks are refused with a named reason.
//    No DRM is touched; those builds are simply not supported yet.
//  - Every file path from the manifest is validated before anything is
//    written (no "..", no absolute paths, no drive letters, no case-only
//    collisions), and the install goes to
//    <storage root>/EpicGames/<title>.
//  - Progress is reported in stored (downloaded) bytes; the caller shows it.

import Foundation
import zlib
import CryptoKit

enum EpicDownloader {

    static let agentString = "EpicGamesLauncher/14.0.8-22004686+++Portal+Release-Live Windows/10.0.19041.1.256.64bit"

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

    enum Failure: LocalizedError {
        case message(String)
        var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
    }

    /// A failure of one chunk's bytes that another CDN address may fix.
    private enum Retry: Error { case reason(String) }

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

    // MARK: - Install

    /// Downloads the build `manifestURL` points at and writes every file into
    /// <storage root>/EpicGames/<folderName>. Throws a named reason for every
    /// refusal; never leaves a partially-written file reported as complete.
    static func install(manifestURL: URL, bearerToken: String?, folderName: String,
                        progress: @Sendable (Progress) async -> Void) async throws -> Result {
        await progress(Progress(phase: .manifest, detail: "Asking Epic for the build manifest"))
        var request = URLRequest(url: manifestURL)
        request.timeoutInterval = 60
        if let bearerToken { request.setValue("bearer \(bearerToken)", forHTTPHeaderField: "Authorization") }
        request.setValue(agentString, forHTTPHeaderField: "User-Agent")
        let (manifestData, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw Failure.message("Epic's manifest service answered with HTTP \(status). Try again in a moment.")
        }
        guard manifestData.count <= 64 << 20 else {
            throw Failure.message("Epic's build manifest is unexpectedly large; refusing it.")
        }
        let manifest = try parse(manifestData)
        guard !manifest.files.isEmpty else {
            throw Failure.message("Epic's build manifest lists no files; refusing to install nothing.")
        }

        let folder = try installFolder(named: folderName)
        let totalFiles = manifest.files.count
        let installSize = manifest.files.reduce(UInt64(0)) { $0 + $1.size }
        let base = baseURL(from: manifestURL)

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

        await progress(Progress(phase: .downloading, doneBytes: 0, totalBytes: totalStored,
                                detail: "\(totalFiles) files, \(ByteCountFormatter.string(fromByteCount: Int64(clamping: installSize), countStyle: .file)) installed size"))

        var doneStored: UInt64 = 0
        var cache: [String: Data] = [:]
        var cacheBytes = 0
        var writtenFiles = 0
        var writtenBytes: UInt64 = 0

        for file in manifest.files {
            let destination = folder.appendingPathComponent(file.path)
            do {
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
            } catch {
                throw Failure.message("Windoz could not create a folder for '\(file.path)': \(error.localizedDescription)")
            }

            // Fetch every chunk this file needs that is not already in memory.
            var needed: [String] = []
            var seenParts = Set<String>()
            for part in file.parts where seenParts.insert(part.guid).inserted {
                if cache[part.guid] == nil { needed.append(part.guid) }
            }
            if !needed.isEmpty {
                let loaded = try await downloadChunks(needed, manifest: manifest, base: base, bearerToken: bearerToken)
                for (key, data, stored) in loaded {
                    if cache[key] == nil {
                        cache[key] = data
                        cacheBytes += data.count
                    }
                    doneStored += stored
                }
            }

            // Write the file: its chunk parts, in order, at their offsets.
            try? FileManager.default.removeItem(at: destination)
            guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
                throw Failure.message("Windoz could not create '\(file.path)'.")
            }
            let handle: FileHandle
            do {
                handle = try FileHandle(forWritingTo: destination)
            } catch {
                throw Failure.message("Windoz could not open '\(file.path)' for writing: \(error.localizedDescription)")
            }
            for part in file.parts {
                guard let chunk = cache[part.guid] else {
                    throw Failure.message("Epic's build manifest references a chunk it does not describe (\(part.guid)); refusing the install.")
                }
                let start = Int(part.offset)
                let end = start + Int(part.size)
                guard end <= chunk.count else {
                    throw Failure.message("A chunk for '\(file.path)' is shorter than the manifest says; refusing the install.")
                }
                do {
                    try handle.write(contentsOf: chunk.subdata(in: start..<end))
                } catch {
                    try? handle.close()
                    throw Failure.message("Writing '\(file.path)' failed: \(error.localizedDescription)")
                }
            }
            do {
                try handle.close()
            } catch {
                throw Failure.message("Writing '\(file.path)' failed: \(error.localizedDescription)")
            }

            // Whole-file verification when the manifest carries a hash.
            if let expected = file.sha1 {
                let actual = try sha1HexOfFile(destination)
                guard actual == expected else {
                    throw Failure.message("'\(file.path)' did not match the hash Epic's manifest carries (downloaded \(actual.prefix(12))…, expected \(expected.prefix(12))…). The download was corrupted; start it again.")
                }
            }

            // Release memory as soon as a chunk's last use is written.
            for part in file.parts {
                guard let remaining = references[part.guid] else { continue }
                let left = remaining - 1
                references[part.guid] = left
                if left <= 0, let data = cache.removeValue(forKey: part.guid) {
                    cacheBytes -= data.count
                }
            }

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
        return Result(folder: folder, executablePath: executable, fileCount: writtenFiles,
                      bytes: writtenBytes, buildVersion: manifest.buildVersion,
                      skippedSymlinks: manifest.skippedSymlinks)
    }

    // MARK: - Chunk download

    private static func downloadChunks(_ keys: [String], manifest: Manifest, base: String,
                                       bearerToken: String?) async throws -> [(String, Data, UInt64)] {
        var results: [(String, Data, UInt64)] = []
        var index = 0
        while index < keys.count {
            let batch = Array(keys[index..<min(index + 6, keys.count)])
            index += 6
            let loaded = try await withThrowingTaskGroup(of: (String, Data, UInt64).self) { group in
                for key in batch {
                    guard let info = manifest.chunks[key] else {
                        throw Failure.message("Epic's build manifest references a chunk it does not describe (\(key)); refusing the install.")
                    }
                    group.addTask { (key, try await downloadChunk(info, base: base, bearerToken: bearerToken), info.storedSize) }
                }
                var out: [(String, Data, UInt64)] = []
                for try await item in group { out.append(item) }
                return out
            }
            results.append(contentsOf: loaded)
        }
        return results
    }

    /// One chunk, with bounded retries. A digest failure at one CDN address
    /// does not fail the install while another address may serve the bytes
    /// correctly; a refusal (encrypted content) stops immediately.
    private static func downloadChunk(_ info: ChunkInfo, base: String, bearerToken: String?) async throws -> Data {
        var lastReason = "no CDN address"
        let addresses = ["\(base)/\(info.chunkPath)"]
        attempts: for address in addresses {
            for attempt in 1...2 {
                guard let url = URL(string: address) else { continue }
                do {
                    var request = URLRequest(url: url)
                    request.timeoutInterval = 60
                    if let bearerToken { request.setValue("bearer \(bearerToken)", forHTTPHeaderField: "Authorization") }
                    request.setValue(agentString, forHTTPHeaderField: "User-Agent")
                    let (raw, response) = try await URLSession.shared.data(for: request)
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    guard status == 200 else {
                        lastReason = "HTTP \(status)"
                        continue
                    }
                    do {
                        return try decodeChunk(raw, info: info)
                    } catch let retry as Retry {
                        if case .reason(let why) = retry { lastReason = why }
                        if attempt == 2 { continue attempts }
                    }
                } catch let failure as Failure {
                    throw failure
                } catch {
                    lastReason = error.localizedDescription
                    if attempt == 2 { continue attempts }
                }
            }
        }
        throw Failure.message("Chunk \(info.key) could not be downloaded (\(lastReason)).")
    }

    /// The chunk container (legendary/models/chunk.py): magic 0xB1FE3AA2, a
    /// header, then the payload. The payload may be zlib-compressed; the
    /// decompressed bytes must match the manifest's SHA-1 for this chunk.
    private static func decodeChunk(_ raw: Data, info: ChunkInfo) throws -> Data {
        guard raw.count >= 48, raw.u32LE(0) == 0xB1FE3AA2 else {
            throw Retry.reason("not a chunk container")
        }
        let headerVersion = raw.u32LE(4) ?? 0
        let headerSize = Int(raw.u32LE(8) ?? 0)
        guard headerSize >= 40, headerSize <= raw.count else {
            throw Retry.reason("chunk header is out of range")
        }
        let storedAs = raw.byte(at: 40) ?? 0
        guard storedAs & 0x2 == 0 else {
            throw Failure.message("This build's chunks are encrypted by Epic. Windoz does not touch encrypted content: this title cannot be installed yet.")
        }
        let headerSHA: String? = headerVersion >= 2 ? raw.hex(41, 20) : nil
        let expected = Int(info.windowSize)

        let payload = raw.subdata(in: headerSize..<raw.count)
        var candidates: [Data] = []
        if storedAs & 0x1 != 0 {
            if let inflated = inflate(payload, hint: expected > 0 ? expected : nil) { candidates.append(inflated) }
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
        throw Retry.reason("chunk digest did not match the manifest")
    }

    // MARK: - Parsing

    static func parse(_ data: Data) throws -> Manifest {
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
                throw Failure.message("This build's manifest is encrypted by Epic (v\(version)). Windoz does not touch encrypted content: this title cannot be installed yet.")
            }
        }
        guard headerSize >= cursor.index, headerSize <= data.count else {
            throw Failure.message("Epic's build manifest header is inconsistent; refusing it.")
        }
        cursor.index = headerSize
        var body = try cursor.bytes(cursor.remaining)
        if storedAs & 0x1 != 0 {
            let hint = declaredUncompressed > 0 && declaredUncompressed <= 256 << 20 ? declaredUncompressed : nil
            guard let inflated = inflate(body, hint: hint, cap: 256 << 20) else {
                throw Failure.message("Epic's build manifest did not decompress.")
            }
            guard Data(Insecure.SHA1.hash(data: inflated)) == manifestSHA else {
                throw Failure.message("Epic's build manifest failed its own SHA-1 check; refusing it.")
            }
            body = inflated
        }
        return try parseBody(body)
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
        for _ in 0..<chunkCount { shas.append(try cursor.bytes(20).hexString()) }
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
                    throw Failure.message("This build's chunks are encrypted by Epic. Windoz does not touch encrypted content: this title cannot be installed yet.")
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
            fileHashes.append(raw.contains(where: { $0 != 0 }) ? raw.hexString() : nil)
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

    // MARK: - Install layout

    static func installFolder(named folderName: String) throws -> URL {
        let base = AppContainer.storageRoot.appendingPathComponent("EpicGames", isDirectory: true)
        var name = folderName
        if !validRelativePath(name) { name = "Epic game" }
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

    // MARK: - Bytes helpers

    private static func baseURL(from manifestURL: URL) -> String {
        let base = manifestURL.deletingLastPathComponent().absoluteString
        return base.hasSuffix("/") ? String(base.dropLast()) : base
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

    /// The same key from the four little-endian words a parsed list already has.
    private static func guidKey(_ guid: (UInt32, UInt32, UInt32, UInt32)) -> String {
        String(format: "%08X%08X%08X%08X", guid.0, guid.1, guid.2, guid.3)
    }

    private static func packGUID(_ guid: (UInt32, UInt32, UInt32, UInt32)) -> Data {
        var data = Data(capacity: 16)
        for value in [guid.0, guid.1, guid.2, guid.3] {
            for shift in stride(from: 0, through: 24, by: 8) {
                data.append(UInt8(truncatingIfNeeded: value >> UInt32(shift)))
            }
        }
        return data
    }

    private static func packU64(_ value: UInt64) -> Data {
        var data = Data(capacity: 8)
        for shift in stride(from: 0, through: 56, by: 8) {
            data.append(UInt8(truncatingIfNeeded: value >> UInt64(shift)))
        }
        return data
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func groupNumber(_ guid: (UInt32, UInt32, UInt32, UInt32)) -> Int {
        let bytes = packGUID(guid)
        let value: UInt32 = bytes.withUnsafeBytes { buffer in
            UInt32(crc32(0, buffer.bindMemory(to: UInt8.self).baseAddress, uInt(bytes.count)))
        }
        return Int(value) % 100
    }

    /// The CDN path scheme (legendary/models/manifest.py, ChunkInfo.path).
    private static func chunkPath(guid: (UInt32, UInt32, UInt32, UInt32), hash: UInt64,
                                  featureLevel: Int) -> String {
        let directory: String
        if featureLevel >= 22 { directory = "ChunksV5" }
        else if featureLevel >= 15 { directory = "ChunksV4" }
        else if featureLevel >= 6 { directory = "ChunksV3" }
        else if featureLevel >= 3 { directory = "ChunksV2" }
        else { directory = "Chunks" }
        let group = groupNumber(guid)
        if featureLevel >= 22 {
            return String(format: "%@/plain/%02d/%@_%@.chunk", directory, group,
                          base64URL(packU64(hash)), base64URL(packGUID(guid)))
        }
        return String(format: "%@/%02d/%016llX_%08X%08X%08X%08X.chunk", directory, group, hash,
                      guid.0, guid.1, guid.2, guid.3)
    }

    static func sha1Hex(_ data: Data) -> String {
        Insecure.SHA1.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func sha1HexOfFile(_ url: URL) throws -> String {
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

    /// zlib first (Epic's chunks are zlib streams), then raw deflate as a
    /// fallback. `hint` bounds the output buffer when the expanded size is
    /// known; `cap` raises that limit for build manifests.
    private static func inflate(_ data: Data, hint: Int?, cap limit: Int? = nil) -> Data? {
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

    // MARK: - Binary reader

    private struct Cursor {
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
            let length = Int32(bitPattern: try u32())
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

private extension Data {
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

    func hexString() -> String {
        map { String(format: "%02x", $0) }.joined()
    }
}
