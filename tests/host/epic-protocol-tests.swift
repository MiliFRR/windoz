// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 125hz
// Windoz Converter Exception: see LICENSE-EXCEPTION.md
//
// Off-device tests for the Epic download protocol (Phase 6). Compiled and run
// by CI on macOS with plain swiftc — no device, no network:
//
//   xcrun swiftc -O -parse-as-library -o epic-host-tests \
//       app-windoz/Sources/Epic/EpicProtocol.swift tests/host/epic-protocol-tests.swift
//   ./epic-host-tests      # exit 0 = all passed
//
// HTTP is a scripted mock (MockTransport); manifests and chunks are synthetic
// bytes built here to Legendary's layouts (legendary/models/manifest.py,
// legendary/models/chunk.py); the whole install flow runs against a temp
// folder. The two 0.4.x device bugs are locked in as regressions:
//   * chunk URLs must never carry the manifest's signed query string, and
//   * the assets response must parse leniently, whatever Epic adds to it.

import Foundation
import Darwin
import CryptoKit
import zlib

@main
struct EpicProtocolHostTests {

    static var failures = 0

    static func main() async {
        testRequestURL()
        testBaseURLStripsQuery()
        testRedactedURL()
        testChunkPaths()
        testAssetsLenientParsing()
        testManifestParse()
        testManifestEncryptedRefused()
        testTraversalRefused()
        testChunkDecodingAndEncryptedRefusal()
        await testInstallFlow()
        await testResumeSkipsFinishedFiles()
        await testFailedFileIsRemoved()
        await testPauseResume()
        await testRetryExhaustion()
        print(failures == 0 ? "ALL PASSED" : "FAILURES: \(failures)")
        exit(failures == 0 ? 0 : 1)
    }

    // MARK: - Expectation plumbing

    static func expect(_ condition: Bool, _ label: String) {
        if condition {
            print("ok   - \(label)")
        } else {
            failures += 1
            print("FAIL - \(label)")
        }
    }

    static func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ label: String) {
        if actual == expected {
            print("ok   - \(label)")
        } else {
            failures += 1
            print("FAIL - \(label)")
            print("       actual:   \(actual)")
            print("       expected: \(expected)")
        }
    }

    // MARK: - URL construction (the 0.4.x bugs)

    static func testRequestURL() {
        let url = EpicProtocol.requestURL(uri: "https://cdn.test/Builds/O/g/BuildManifest-1.manifest",
                                          queryParams: [("accountId", "42"), ("token", "tok+A/B=C")])
        expectEqual(url?.absoluteString,
                    "https://cdn.test/Builds/O/g/BuildManifest-1.manifest?accountId=42&token=tok+A/B=C",
                    "manifest URL joins the signed params verbatim (no re-encoding)")
        expectEqual(EpicProtocol.requestURL(uri: "https://cdn.test/x.manifest", queryParams: [])?.absoluteString,
                    "https://cdn.test/x.manifest",
                    "manifest URL with no params is the plain uri")
    }

    static func testBaseURLStripsQuery() {
        let withQuery = URL(string: "https://cdn.test/Builds/Org/o-1/guid-1/BuildManifest-v1.manifest?accountId=42&token=SECRET")!
        expectEqual(EpicProtocol.baseURL(fromManifestURL: withQuery),
                    "https://cdn.test/Builds/Org/o-1/guid-1",
                    "chunk base drops the manifest query string (the 0.4.x instant-404 bug)")
        let plain = URL(string: "https://cdn.test/Builds/Org/o-1/guid-1/BuildManifest-v1.manifest")!
        expectEqual(EpicProtocol.baseURL(fromManifestURL: plain),
                    "https://cdn.test/Builds/Org/o-1/guid-1",
                    "chunk base is the manifest URI's parent")
    }

    static func testRedactedURL() {
        let url = URL(string: "https://cdn.test/a/b.manifest?accountId=42&token=SECRET")!
        let text = EpicProtocol.redactedURL(url)
        expect(!text.contains("SECRET") && text.contains("2 params redacted"),
               "redacted URL hides query values but says how many there were")
    }

    // MARK: - Chunk paths (legendary models/manifest.py ChunkInfo.path)

    static func testChunkPaths() {
        let guid: (UInt32, UInt32, UInt32, UInt32) = (0x11111111, 0x22222222, 0x33333333, 0x44444444)
        var packedGUID: [UInt8] = []
        for value in [guid.0, guid.1, guid.2, guid.3] {
            packedGUID += [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF),
                           UInt8((value >> 16) & 0xFF), UInt8((value >> 24) & 0xFF)]
        }
        let group = Int(UInt32(truncatingIfNeeded: crc32(0, packedGUID, uInt(packedGUID.count))) % 100)
        expectEqual(EpicProtocol.chunkPath(guid: guid, hash: 0xAABBCCDDEEFF0011, featureLevel: 18),
                    String(format: "ChunksV4/%02d/AABBCCDDEEFF0011_11111111222222223333333344444444.chunk", group),
                    "v18 chunk path: ChunksV4, uppercase hash and GUID, grouped by CRC32")

        let hashBytes: [UInt8] = [0x08, 0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01] // LE of 0x0102030405060708
        let guidBytes: [UInt8] = [1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
        let groupV5 = Int(UInt32(truncatingIfNeeded: crc32(0, guidBytes, uInt(guidBytes.count))) % 100)
        expectEqual(EpicProtocol.chunkPath(guid: (1, 0, 0, 0), hash: 0x0102030405060708, featureLevel: 22),
                    "ChunksV5/plain/\(String(format: "%02d", groupV5))/\(b64url(hashBytes))_\(b64url(guidBytes)).chunk",
                    "v22 chunk path: ChunksV5, base64url parts, 'plain' (encrypted refused earlier)")
    }

    static func b64url(_ bytes: [UInt8]) -> String {
        Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: - The assets response (the other 0.4.x instant-failure)

    static func testAssetsLenientParsing() {
        let json = """
        {"elements": [
            {"appName": "Fortnite", "catalogItemId": "abc", "hash": "deadbeef",
             "unknownField": {"nested": [1, 2, 3]},
             "manifests": [{"uri": "https://cdn.test/m1.manifest",
                            "queryParams": [{"name": "token", "value": "t1"}], "extra": 5},
                           {"uri": "", "queryParams": []}]},
            {"appName": "NoManifests"},
            "junk-element"
        ]}
        """
        let elements = EpicProtocol.parseAssetElements(Data(json.utf8))
        expectEqual(elements.count, 2, "lenient parse keeps every object element, drops junk")
        expectEqual(elements.first?.appName, "Fortnite", "lenient parse reads appName")
        expectEqual(elements.first?.hash, "deadbeef", "lenient parse keeps the manifest SHA-1")
        expectEqual(elements.first?.manifests.count, 1, "empty manifest URIs are dropped, unknown fields ignored")
        expectEqual(elements.first?.manifests.first?.queryParams.first?.value, "t1", "lenient parse reads query params")

        let bare = Data(#"[{"appName": "A", "manifests": []}]"#.utf8)
        expectEqual(EpicProtocol.parseAssetElements(bare).count, 1, "lenient parse accepts a bare array (v1 fallback)")
        expectEqual(EpicProtocol.parseAssetElements(Data("<html>".utf8)).count, 0,
                    "a non-JSON answer parses to nothing, not a crash")
    }

    // MARK: - Fixture building (bytes exactly as Legendary reads them)

    static func u32(_ value: UInt32) -> Data {
        var LE = value.littleEndian
        return Data(bytes: &LE, count: 4)
    }

    static func u64(_ value: UInt64) -> Data {
        var LE = value.littleEndian
        return Data(bytes: &LE, count: 8)
    }

    static func fstring(_ text: String) -> Data {
        var data = u32(UInt32(text.utf8.count + 1))
        data.append(Data(text.utf8))
        data.append(0)
        return data
    }

    static func sha1(_ data: Data) -> Data { Data(Insecure.SHA1.hash(data: data)) }

    static func hexBytes(_ hex: String) -> Data {
        var data = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
            data.append(UInt8(hex[index..<next], radix: 16) ?? 0)
            index = next
        }
        return data
    }

    static func patchU32(_ data: inout Data, at offset: Int, value: UInt32) {
        var LE = value.littleEndian
        data.replaceSubrange(offset..<offset + 4, with: Data(bytes: &LE, count: 4))
    }

    static func zlibCompress(_ data: Data) -> Data {
        var output = Data(count: Int(compressBound(uLong(data.count))))
        var outputLength = uLongf(output.count)
        let status = data.withUnsafeBytes { source -> Int32 in
            output.withUnsafeMutableBytes { destination -> Int32 in
                compress2(destination.bindMemory(to: Bytef.self).baseAddress, &outputLength,
                          source.bindMemory(to: Bytef.self).baseAddress, uLong(data.count), 1)
            }
        }
        precondition(status == Z_OK, "test fixture compression failed")
        output.count = Int(outputLength)
        return output
    }

    struct ChunkFixture {
        let guid: (UInt32, UInt32, UInt32, UInt32)
        let hash: UInt64
        let payload: Data   // uncompressed bytes
        let compressed: Bool
        var stored: Data { compressed ? zlibCompress(payload) : payload }
    }

    struct FileFixture {
        let path: String
        let parts: [(chunk: Int, offset: UInt32, size: UInt32)]
        let sha1: String?
        var executable = false
    }

    static func pattern(seed: UInt8, count: Int) -> Data {
        Data((0..<count).map { UInt8((UInt32($0) &* 31 &+ UInt32(seed)) & 0xFF) })
    }

    static func makeChunks() -> [ChunkFixture] {
        [
            ChunkFixture(guid: (0x00000001, 0x00000002, 0x00000003, 0x00000004),
                         hash: 0x1000000000000001, payload: pattern(seed: 1, count: 512), compressed: true),
            ChunkFixture(guid: (0x00000005, 0x00000006, 0x00000007, 0x00000008),
                         hash: 0x2000000000000002, payload: pattern(seed: 2, count: 512), compressed: false),
            ChunkFixture(guid: (0x00000009, 0x0000000A, 0x0000000B, 0x0000000C),
                         hash: 0x3000000000000003, payload: pattern(seed: 3, count: 512), compressed: true),
        ]
    }

    static func makeFiles(chunks: [ChunkFixture]) -> [FileFixture] {
        func content(_ parts: [(chunk: Int, offset: UInt32, size: UInt32)]) -> Data {
            var data = Data()
            for part in parts {
                let payload = chunks[part.chunk].payload
                let start = payload.startIndex + Int(part.offset)
                data.append(payload[start..<start + Int(part.size)])
            }
            return data
        }
        let p1: [(chunk: Int, offset: UInt32, size: UInt32)] = [(0, 0, 256)]
        let p2: [(chunk: Int, offset: UInt32, size: UInt32)] = [(0, 256, 256), (1, 0, 256)]
        let p3: [(chunk: Int, offset: UInt32, size: UInt32)] = [(2, 0, 512)]
        return [
            FileFixture(path: "bin/Game.exe", parts: p1, sha1: EpicProtocol.sha1Hex(content(p1)), executable: true),
            FileFixture(path: "data/pack.bin", parts: p2, sha1: EpicProtocol.sha1Hex(content(p2)), executable: false),
            FileFixture(path: "data/extra.bin", parts: p3, sha1: EpicProtocol.sha1Hex(content(p3)), executable: false),
        ]
    }

    static func makeChunk(_ fixture: ChunkFixture, storedAsOverride: UInt8? = nil) -> Data {
        let stored = fixture.stored
        var data = Data()
        data.append(u32(0xB1FE3AA2))                    // magic
        data.append(u32(3))                             // header version
        data.append(u32(66))                            // header size
        data.append(u32(UInt32(stored.count)))          // stored (compressed) size
        data.append(EpicProtocol.packGUID(fixture.guid))
        data.append(u64(fixture.hash))
        data.append(storedAsOverride ?? (fixture.compressed ? 1 : 0))
        data.append(sha1(fixture.payload))              // SHA-1 of the decompressed payload
        data.append(2)                                  // hash type: sha
        data.append(u32(UInt32(fixture.payload.count))) // uncompressed size
        data.append(stored)
        return data
    }

    static func makeManifest(chunks: [ChunkFixture], files: [FileFixture],
                             featureLevel: Int = 18, fmlVersion: Int = 1,
                             appName: String = "TestApp", buildVersion: String = "build-1",
                             secretGUID: Bool = false) -> Data {
        var body = Data()

        // ManifestMeta (legendary ManifestMeta.read)
        let metaStart = body.count
        body.append(u32(0))                       // size placeholder
        body.append(1)                            // data version (build id present)
        body.append(u32(UInt32(featureLevel)))
        body.append(0)                            // is file data
        body.append(u32(0))                       // app id
        body.append(fstring(appName))
        body.append(fstring(buildVersion))
        body.append(fstring("Game.exe"))
        body.append(fstring(""))
        body.append(u32(0))                       // prerequisite count
        body.append(fstring(""))                  // prerequisite name
        body.append(fstring(""))                  // prerequisite path
        body.append(fstring(""))                  // prerequisite arguments
        body.append(fstring("build-id"))          // data version >= 1
        patchU32(&body, at: metaStart, value: UInt32(body.count - metaStart))

        // Chunk data list (legendary CDL.read)
        let cdlStart = body.count
        body.append(u32(0))                       // size placeholder
        body.append(1)                            // list version
        body.append(u32(UInt32(chunks.count)))
        for chunk in chunks { body.append(EpicProtocol.packGUID(chunk.guid)) }
        for chunk in chunks { body.append(u64(chunk.hash)) }
        for chunk in chunks { body.append(sha1(chunk.payload)) }
        for _ in chunks { body.append(0) }        // group numbers (recomputed by the parser)
        for chunk in chunks { body.append(u32(UInt32(chunk.payload.count))) } // window size
        for chunk in chunks { body.append(u64(UInt64(chunk.stored.count))) }  // stored size
        if secretGUID {
            for _ in chunks { body.append(hexBytes("11111111111111111111111111111111")) }
            for _ in chunks { body.append(u32(0)) }
            for _ in chunks { body.append(Data(count: 16)) }
        }
        patchU32(&body, at: cdlStart, value: UInt32(body.count - cdlStart))

        // File manifest list (legendary FML.read)
        let fmlStart = body.count
        body.append(u32(0))                       // size placeholder
        body.append(UInt8(fmlVersion))
        body.append(u32(UInt32(files.count)))
        for file in files { body.append(fstring(file.path)) }
        for _ in files { body.append(fstring("")) }                       // symlink targets
        for file in files { body.append(file.sha1.map { hexBytes($0) } ?? Data(count: 20)) }
        for file in files { body.append(file.executable ? 4 : 0) }
        for _ in files { body.append(u32(0)) }                            // install tags
        for file in files {
            body.append(u32(UInt32(file.parts.count)))
            for part in file.parts {
                body.append(u32(28))                                      // record size
                body.append(EpicProtocol.packGUID(chunks[part.chunk].guid))
                body.append(u32(part.offset))
                body.append(u32(part.size))
            }
        }
        if fmlVersion >= 1 {
            for _ in files { body.append(u32(0)) }                        // no MD5
            for _ in files { body.append(fstring("application/octet-stream")) }
        }
        if fmlVersion >= 2 {
            for _ in files { body.append(Data(count: 32)) }               // SHA-256 block
        }
        patchU32(&body, at: fmlStart, value: UInt32(body.count - fmlStart))

        // Header, uncompressed body, v18 (or v22 with a secret GUID for the
        // encrypted-refusal test)
        var data = Data()
        data.append(u32(0x44BEC00C))
        data.append(u32(secretGUID ? 73 : 41))    // header size
        data.append(u32(UInt32(body.count)))      // uncompressed size
        data.append(u32(0))                       // compressed size
        data.append(sha1(body))
        data.append(0)                            // stored as: raw
        data.append(u32(secretGUID ? 22 : 18))    // version
        if secretGUID {
            data.append(hexBytes("22222222222222222222222222222222"))
            data.append(Data(count: 16))
        }
        data.append(body)
        return data
    }

    // MARK: - Manifest parsing

    static func testManifestParse() {
        let chunks = makeChunks()
        let files = makeFiles(chunks: chunks)
        let manifestData = makeManifest(chunks: chunks, files: files)
        do {
            let manifest = try EpicProtocol.parseManifest(manifestData)
            expectEqual(manifest.appName, "TestApp", "manifest: app name")
            expectEqual(manifest.buildVersion, "build-1", "manifest: build version")
            expectEqual(manifest.featureLevel, 18, "manifest: feature level")
            expectEqual(manifest.files.count, 3, "manifest: file count")
            expectEqual(manifest.chunks.count, 3, "manifest: chunk count")
            expect(manifest.files.first(where: { $0.path == "bin/Game.exe" })?.executable == true,
                   "manifest: executable flag")
            let second = manifest.files.first { $0.path == "data/pack.bin" }
            expectEqual(second?.parts.count, 2, "manifest: chunk part count")
            expectEqual(second?.parts.first?.offset, 256, "manifest: chunk part offset")
            let key = EpicProtocol.guidKey(chunks[0].guid)
            expectEqual(manifest.chunks[key]?.windowSize, UInt32(chunks[0].payload.count), "manifest: window size")
            expect(manifest.chunks[key]?.chunkPath.hasPrefix("ChunksV4/") == true, "manifest: chunk path directory")
        } catch {
            expect(false, "manifest parse threw: \(error)")
        }
        do {
            _ = try EpicProtocol.parseManifest(manifestData, expectedSHA1: String(repeating: "0", count: 40))
            expect(false, "a manifest that fails the launcher service's hash must be refused")
        } catch {
            expect((error as? EpicProtocol.Failure)?.errorDescription?.contains("did not match the hash") == true,
                   "the launcher service's hash refusal is a sentence")
        }
        do {
            _ = try EpicProtocol.parseManifest(makeManifest(chunks: chunks, files: files, fmlVersion: 2))
            expect(true, "manifest: fml v2 (SHA-256 block) parses")
        } catch {
            expect(false, "manifest: fml v2 threw: \(error)")
        }
    }

    static func testManifestEncryptedRefused() {
        let chunks = makeChunks()
        let data = makeManifest(chunks: chunks, files: makeFiles(chunks: chunks), secretGUID: true)
        do {
            _ = try EpicProtocol.parseManifest(data)
            expect(false, "an encrypted manifest must be refused")
        } catch let failure as EpicProtocol.Failure {
            if case .encrypted(let text) = failure {
                expect(text.contains("encrypted"), "encrypted manifest refusal names the reason")
            } else {
                expect(false, "encrypted manifest refused as .encrypted, got: \(failure)")
            }
        } catch {
            expect(false, "encrypted manifest threw the wrong error: \(error)")
        }
    }

    static func testTraversalRefused() {
        let chunks = makeChunks()
        var files = makeFiles(chunks: chunks)
        files[1] = FileFixture(path: "..\\..\\Windows\\System32\\evil.dll", parts: files[1].parts,
                               sha1: files[1].sha1)
        do {
            _ = try EpicProtocol.parseManifest(makeManifest(chunks: chunks, files: files))
            expect(false, "a traversal path must be refused")
        } catch {
            expect((error as? EpicProtocol.Failure)?.errorDescription?.contains("will not write") == true,
                   "traversal refusal is a sentence")
        }
    }

    // MARK: - Chunk decoding

    static func testChunkDecodingAndEncryptedRefusal() {
        let chunks = makeChunks()

        let encrypted = makeChunk(chunks[0], storedAsOverride: 2)
        let info0 = EpicProtocol.ChunkInfo(key: EpicProtocol.guidKey(chunks[0].guid),
                                           sha1: EpicProtocol.sha1Hex(chunks[0].payload),
                                           storedSize: UInt64(encrypted.count),
                                           windowSize: UInt32(chunks[0].payload.count),
                                           chunkPath: EpicProtocol.chunkPath(guid: chunks[0].guid, hash: chunks[0].hash, featureLevel: 18))
        do {
            _ = try EpicProtocol.decodeChunk(encrypted, info: info0)
            expect(false, "an encrypted chunk must be refused")
        } catch let failure as EpicProtocol.Failure {
            if case .encrypted = failure {
                expect(true, "encrypted chunk refused by design")
            } else {
                expect(false, "encrypted chunk refused as .encrypted, got: \(failure)")
            }
        } catch {
            expect(false, "encrypted chunk threw the wrong error: \(error)")
        }

        let compressed = makeChunk(chunks[0])
        do {
            expectEqual(try EpicProtocol.decodeChunk(compressed, info: info0), chunks[0].payload,
                        "a zlib chunk decodes to its payload")
        } catch {
            expect(false, "compressed chunk decode threw: \(error)")
        }

        let stored = makeChunk(chunks[1])
        let info1 = EpicProtocol.ChunkInfo(key: EpicProtocol.guidKey(chunks[1].guid),
                                           sha1: EpicProtocol.sha1Hex(chunks[1].payload),
                                           storedSize: UInt64(stored.count),
                                           windowSize: UInt32(chunks[1].payload.count),
                                           chunkPath: EpicProtocol.chunkPath(guid: chunks[1].guid, hash: chunks[1].hash, featureLevel: 18))
        do {
            expectEqual(try EpicProtocol.decodeChunk(stored, info: info1), chunks[1].payload,
                        "a stored chunk decodes to its payload")
        } catch {
            expect(false, "stored chunk decode threw: \(error)")
        }
    }

    // MARK: - The mock network

    final class MockTransport: EpicProtocol.Transport, @unchecked Sendable {
        private let lock = NSLock()
        private var routes: [String: () async throws -> (Data, Int)] = [:]
        private var recorded: [URL] = []

        func route(_ url: String, _ handler: @escaping () async throws -> (Data, Int)) {
            lock.lock(); routes[url] = handler; lock.unlock()
        }

        func get(_ url: URL, timeout: TimeInterval) async throws -> (body: Data, status: Int) {
            lock.lock()
            recorded.append(url)
            let handler = routes[url.absoluteString]
            lock.unlock()
            guard let handler else { throw URLError(.unsupportedURL) }
            return try await handler()
        }

        var requests: [URL] {
            lock.lock(); defer { lock.unlock() }
            return recorded
        }

        func requestCount(_ url: String) -> Int {
            requests.filter { $0.absoluteString == url }.count
        }
    }

    final class Attempts: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func next() -> Int {
            lock.lock(); defer { lock.unlock() }
            count += 1
            return count
        }
        var value: Int {
            lock.lock(); defer { lock.unlock() }
            return count
        }
    }

    final class AsyncGate: @unchecked Sendable {
        private let lock = NSLock()
        private var waiters: [CheckedContinuation<Void, Never>] = []
        private var isOpen = false
        func wait() async {
            lock.lock()
            if isOpen { lock.unlock(); return }
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
                lock.unlock()
            }
        }
        func open() {
            lock.lock()
            isOpen = true
            let waiting = waiters
            waiters = []
            lock.unlock()
            for waiter in waiting { waiter.resume() }
        }
    }

    final class Fired: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Never>?
        private var didFire = false
        func fire() {
            lock.lock()
            let waiting = continuation
            continuation = nil
            didFire = true
            lock.unlock()
            waiting?.resume()
        }
        func wait() async {
            lock.lock()
            if didFire { lock.unlock(); return }
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                lock.unlock()
            }
        }
    }

    // MARK: - The install flow

    struct Harness {
        let chunks: [ChunkFixture]
        let files: [FileFixture]
        let manifestData: Data
        let base: String
        let manifestURL: URL
        let chunkURLs: [String]
    }

    static func makeHarness(files: [FileFixture]? = nil) -> Harness {
        let chunks = makeChunks()
        let chosen = files ?? makeFiles(chunks: chunks)
        let manifestData = makeManifest(chunks: chunks, files: chosen)
        let base = "https://mock-cdn.test/Builds/Org/o-1/guid-1"
        let manifestURL = EpicProtocol.requestURL(uri: base + "/BuildManifest-1.manifest",
                                                  queryParams: [("accountId", "42"), ("token", "tok+A/B=C")])!
        let chunkURLs = chunks.map { base + "/" + EpicProtocol.chunkPath(guid: $0.guid, hash: $0.hash, featureLevel: 18) }
        return Harness(chunks: chunks, files: chosen, manifestData: manifestData, base: base,
                       manifestURL: manifestURL, chunkURLs: chunkURLs)
    }

    static func tempFolder(_ name: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("windoz-epic-tests", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.removeItem(at: url)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Every route the install needs: the manifest and each chunk. `retryFirst`
    /// makes chunk 0 answer HTTP 500 once.
    static func routeAll(_ transport: MockTransport, _ h: Harness, retryFirst: Attempts? = nil) {
        transport.route(h.manifestURL.absoluteString) { return (h.manifestData, 200) }
        for (index, url) in h.chunkURLs.enumerated() {
            transport.route(url) {
                if let retryFirst, index == 0, retryFirst.next() == 1 { return (Data(), 500) }
                return (makeChunk(h.chunks[index]), 200)
            }
        }
    }

    static func assembledContent(_ h: Harness, _ fileIndex: Int) -> Data {
        var data = Data()
        for part in h.files[fileIndex].parts {
            let payload = h.chunks[part.chunk].payload
            let start = payload.startIndex + Int(part.offset)
            data.append(payload[start..<start + Int(part.size)])
        }
        return data
    }

    static func fastOptions() -> EpicProtocol.Options {
        var options = EpicProtocol.Options()
        options.retryDelays = [0.01, 0.01]
        return options
    }

    static func testInstallFlow() async {
        let h = makeHarness()
        let transport = MockTransport()
        let attempts = Attempts()
        routeAll(transport, h, retryFirst: attempts)
        let folder = tempFolder("full-flow")
        do {
            let result = try await EpicProtocol.install(
                manifestURL: h.manifestURL,
                expectedManifestSHA1: EpicProtocol.sha1Hex(h.manifestData),
                folder: folder, transport: transport, options: fastOptions(),
                log: { _ in }, progress: { _ in })
            expectEqual(result.fileCount, 3, "install: three files written")
            for (index, file) in h.files.enumerated() {
                let written = try? Data(contentsOf: folder.appendingPathComponent(file.path))
                expect(written == assembledContent(h, index), "install: '\(file.path)' bytes match")
            }
            expectEqual(attempts.value, 2, "install: chunk 0 retried once after HTTP 500")
            expectEqual(transport.requestCount(h.chunkURLs[0]), 2, "install: two requests for the retried chunk")
            expectEqual(transport.requestCount(h.manifestURL.absoluteString), 1, "install: manifest fetched once")
            let chunkRequests = transport.requests.filter { $0.absoluteString.contains("/Chunks") }
            expect(chunkRequests.allSatisfy { !$0.absoluteString.contains("?") },
                   "install: chunk URLs never carry the manifest's query string (0.4.x 404 bug)")
            expect(transport.requests.contains { $0.absoluteString.hasSuffix("token=tok+A/B=C") },
                   "install: the signed manifest params are sent verbatim")
        } catch {
            expect(false, "install flow threw: \(error)")
        }
    }

    static func testResumeSkipsFinishedFiles() async {
        let h = makeHarness()
        let folder = tempFolder("resume")
        do {
            let first = MockTransport()
            routeAll(first, h)
            _ = try await EpicProtocol.install(manifestURL: h.manifestURL, expectedManifestSHA1: nil,
                                               folder: folder, transport: first, options: fastOptions(),
                                               log: { _ in }, progress: { _ in })
            expectEqual(first.requests.filter { $0.absoluteString.contains("/Chunks") }.count, 3,
                        "resume: first run fetches all three chunks")
            let second = MockTransport()
            routeAll(second, h)
            let result = try await EpicProtocol.install(manifestURL: h.manifestURL, expectedManifestSHA1: nil,
                                                        folder: folder, transport: second, options: fastOptions(),
                                                        log: { _ in }, progress: { _ in })
            expectEqual(result.fileCount, 3, "resume: second run counts all files")
            expectEqual(second.requests.filter { $0.absoluteString.contains("/Chunks") }.count, 0,
                        "resume: verified files are kept — no chunk is downloaded again")
        } catch {
            expect(false, "resume test threw: \(error)")
        }
    }

    static func testFailedFileIsRemoved() async {
        let chunks = makeChunks()
        var files = makeFiles(chunks: chunks)
        // A wrong but non-zero hash — zero is the format's "no hash recorded"
        // sentinel (locked in by the second case below), not a claim about the
        // bytes.
        files[2] = FileFixture(path: files[2].path, parts: files[2].parts,
                               sha1: String(repeating: "ab", count: 20))
        let h = makeHarness(files: files)
        let transport = MockTransport()
        routeAll(transport, h)
        let folder = tempFolder("failed-file")
        do {
            _ = try await EpicProtocol.install(manifestURL: h.manifestURL, expectedManifestSHA1: nil,
                                               folder: folder, transport: transport, options: fastOptions(),
                                               log: { _ in }, progress: { _ in })
            expect(false, "a file that fails its manifest hash must fail the install")
        } catch {
            let text = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            expect(text.contains("did not match the hash"), "the corrupt-file refusal is a sentence")
            expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("bin/Game.exe").path),
                   "files already written are kept when a later file fails")
            expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("data/extra.bin").path),
                   "the file that failed is removed — no half-file is left behind")
        }

        // All-zero file hashes are the format's "no hash recorded" — the file
        // installs and verification simply does not apply.
        var zeroFiles = makeFiles(chunks: chunks)
        zeroFiles[2] = FileFixture(path: zeroFiles[2].path, parts: zeroFiles[2].parts,
                                   sha1: String(repeating: "0", count: 40))
        let zeroHarness = makeHarness(files: zeroFiles)
        let zeroTransport = MockTransport()
        routeAll(zeroTransport, zeroHarness)
        let zeroFolder = tempFolder("zero-hash")
        do {
            let result = try await EpicProtocol.install(manifestURL: zeroHarness.manifestURL, expectedManifestSHA1: nil,
                                                        folder: zeroFolder, transport: zeroTransport, options: fastOptions(),
                                                        log: { _ in }, progress: { _ in })
            expectEqual(result.fileCount, 3, "an all-zero file hash means 'no hash recorded', not a mismatch")
        } catch {
            expect(false, "zero-hash install threw: \(error)")
        }
    }

    static func testPauseResume() async {
        let h = makeHarness()
        let transport = MockTransport()
        let gate = AsyncGate()
        let blocker = Fired()
        let control = EpicProtocol.InstallControl()
        transport.route(h.manifestURL.absoluteString) { return (h.manifestData, 200) }
        transport.route(h.chunkURLs[0]) { return (makeChunk(h.chunks[0]), 200) }
        transport.route(h.chunkURLs[1]) {
            blocker.fire()
            await gate.wait()
            return (makeChunk(h.chunks[1]), 200)
        }
        transport.route(h.chunkURLs[2]) { return (makeChunk(h.chunks[2]), 200) }
        let folder = tempFolder("pause-resume")
        let task = Task { try await EpicProtocol.install(
            manifestURL: h.manifestURL, expectedManifestSHA1: nil, folder: folder,
            transport: transport, control: control, options: fastOptions(),
            log: { _ in }, progress: { _ in }) }
        await blocker.wait()          // the second chunk's request is in flight
        control.pause()
        gate.open()                   // let it finish; the loop must stop before the next chunk
        try? await Task.sleep(nanoseconds: 300_000_000)
        expectEqual(transport.requestCount(h.chunkURLs[2]), 0, "pause: no further chunk is fetched while paused")
        control.resume()
        do {
            let result = try await task.value
            expectEqual(result.fileCount, 3, "pause/resume: install finishes after resume")
            expectEqual(transport.requestCount(h.chunkURLs[2]), 1, "pause/resume: the remaining chunk is fetched exactly once")
        } catch {
            expect(false, "pause/resume install threw: \(error)")
        }
    }

    static func testRetryExhaustion() async {
        let h = makeHarness()
        let transport = MockTransport()
        transport.route(h.manifestURL.absoluteString) { return (h.manifestData, 200) }
        transport.route(h.chunkURLs[0]) { return (Data(), 500) }
        transport.route(h.chunkURLs[1]) { return (makeChunk(h.chunks[1]), 200) }
        transport.route(h.chunkURLs[2]) { return (makeChunk(h.chunks[2]), 200) }
        let folder = tempFolder("retry-exhaustion")
        do {
            _ = try await EpicProtocol.install(manifestURL: h.manifestURL, expectedManifestSHA1: nil,
                                               folder: folder, transport: transport, options: fastOptions(),
                                               log: { _ in }, progress: { _ in })
            expect(false, "a chunk that always answers HTTP 500 must fail the install")
        } catch {
            let text = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            expect(text.contains("could not be downloaded"), "retry exhaustion names the refusal")
            expectEqual(transport.requestCount(h.chunkURLs[0]), 3,
                        "retry exhaustion: three attempts for the failing chunk (two retry delays)")
        }
    }
}
