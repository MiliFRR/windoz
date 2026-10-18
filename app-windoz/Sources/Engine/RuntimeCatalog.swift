// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 125hz
// Windoz Converter Exception: see LICENSE-EXCEPTION.md
//
// Phase 5 — Windows runtimes. Windoz never bundles Microsoft's runtime
// binaries: every row here either is already provided by the engine (Wine's
// built-ins, the pinned x86-64 vcruntime overlay) or points at the vendor's
// own official download, which the user fetches on the device.
//
// Rules this file keeps:
//  - The catalog is the bundled `runtime-manifest.json` (Resources), so the
//    list, the URLs and the hashes are visible in the build, not in code.
//  - A `sha256` pin is verified exactly. A mismatch is a stop, not a warning:
//    Windoz refuses to install a binary whose bytes changed (stale file).
//  - An entry without a pin freezes the SHA-256 of its first download in the
//    per-prefix ledger and refuses any later change until the user accepts it
//    explicitly ("Accept the vendor's new file") — never a silent install.
//  - Downloads retry with backoff (2 s, 8 s, then a five-minute cooling-off
//    recorded in the ledger), reuse a verified cached file, and never run at
//    app start — only from Settings, the setup screen, or a user's tap.
//  - Installer components install by running the vendor's own installer in a
//    real Windows session (the engine's normal launch path, direct mode).
//    Windoz runs one session per launch of the app, so the copy says so.
//    If the installer session cannot confirm what it left behind, the row
//    says that too — "ran on <date>", not "installed".
// Log tag: [runtime].

import Foundation
import SwiftUI

// MARK: - Manifest

/// One component of the runtime catalog (Resources/runtime-manifest.json).
struct RuntimeSpec: Codable, Identifiable, Equatable, Hashable {
    enum Kind: String, Codable {
        case mono           // Wine Mono: downloaded and unpacked by the app itself
        case engine         // the engine already provides it — nothing to install
        case installer      // vendor installer, run in a Windows session
        case provider       // handled elsewhere (Steam components, per-game redists)
        case unavailable    // cannot work in this build; the note says why
    }
    enum Arch: String, Codable { case x64, x86, any }

    var id: String
    var title: String
    var detail: String
    var kind: Kind
    var arch: Arch = .any
    /// The vendor's own download. Never a mirror, never Windoz's server.
    var url: String?
    /// Pinned SHA-256. When absent the first download's hash is frozen instead.
    var sha256: String?
    var bytes: Int64?
    /// Silent flags for an installer session ("/install /quiet /norestart").
    var installArgs: String?
    /// Prefix-relative files that indicate the component is present.
    var probeFiles: [String] = []
    var note: String?
}

struct RuntimeManifest: Codable {
    var version: Int
    var note: String?
    var components: [RuntimeSpec]
}

// MARK: - State and ledger

/// What a component's row shows. `providedByEngine` and `installed` are
/// satisfied; `sessionRan` is honest doubt (handed to a session, not confirmed);
/// everything else is a named step the user can take.
enum RuntimeComponentState: Equatable {
    case unknown
    case providedByEngine(String)
    case unavailable(String)
    case missing(String)
    case downloading(Double)
    case staged(String)
    case installing
    case sessionRan(Date)
    case installed(Date?)
    case failed(String)

    var isSatisfied: Bool {
        switch self {
        case .providedByEngine, .installed: return true
        default: return false
        }
    }

    var isBusy: Bool { if case .downloading = self { return true }; if case .installing = self { return true }; return false }
}

/// Per-prefix record of what was downloaded (with which hash), what ran, and
/// what failed. Lives at `<prefix>/windoz-runtimes.json` so it travels with the
/// Windows environment it describes.
struct RuntimeLedger: Codable {
    struct Record: Codable {
        var recordedSHA256: String?
        var finalURL: String?
        var bytes: Int64?
        var downloadedAt: Date?
        /// When an installer session was handed to the engine.
        var ranAt: Date?
        /// When the prefix files confirmed the install.
        var installedAt: Date?
        var attempts: Int = 0
        var lastError: String?
        var nextAttemptAt: Date?
    }
    var records: [String: Record] = [:]

    static func load(from url: URL) -> RuntimeLedger {
        guard let data = try? Data(contentsOf: url) else { return RuntimeLedger() }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(RuntimeLedger.self, from: data)) ?? RuntimeLedger()
    }

    func save(to url: URL) {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(self) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

enum RuntimeInstallError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

// MARK: - The installer

@MainActor
final class RuntimeInstaller: ObservableObject {
    static let shared = RuntimeInstaller()

    @Published private(set) var specs: [RuntimeSpec] = []
    @Published private(set) var states: [String: RuntimeComponentState] = [:]
    @Published private(set) var manifestProblem: String?

    private var prefixRef: PrefixManager?
    private var ledger = RuntimeLedger()
    private var downloads: [String: URLSessionDownloadTask] = [:]
    private var observations: [String: NSKeyValueObservation] = [:]

    /// Where downloaded installers are cached: Documents when the device allows
    /// it, then Library, then tmp — same negotiation as the game downloads.
    lazy var staging: URL =
        AppContainer.writableDirectory(named: "windoz-runtimes",
                                       among: [AppContainer.documents, AppContainer.libraryRoot, AppContainer.temporary])
        ?? AppContainer.runtimes

    private var ledgerURL: URL? { prefixRef?.url.appendingPathComponent("windoz-runtimes.json") }

    private init() { loadManifest() }

    private func loadManifest() {
        guard let url = Bundle.main.url(forResource: "runtime-manifest", withExtension: "json") else {
            manifestProblem = "This build has no runtime manifest (Resources/runtime-manifest.json is missing)."
            return
        }
        do {
            let data = try Data(contentsOf: url)
            let manifest = try JSONDecoder().decode(RuntimeManifest.self, from: data)
            specs = manifest.components
            manifestProblem = nil
        } catch {
            manifestProblem = "The runtime manifest could not be read: \(error.localizedDescription)"
        }
    }

    // MARK: Probing

    /// Re-reads the prefix and the ledger and recomputes every row. Never runs
    /// at idle app start: callers are Settings, the setup screen and the launch
    /// pipeline (which happens on a user's tap).
    func refresh(prefix: PrefixManager) {
        prefixRef = prefix
        ledger = ledgerURL.map(RuntimeLedger.load(from:)) ?? RuntimeLedger()
        for spec in specs {
            // A live download or session keeps its state; refresh must not
            // knock it back to "missing" while it is in flight.
            if let current = states[spec.id], current.isBusy { continue }
            states[spec.id] = state(for: spec, in: prefix)
        }
    }

    private func state(for spec: RuntimeSpec, in prefix: PrefixManager) -> RuntimeComponentState {
        switch spec.kind {
        case .mono:
            return monoState()
        case .engine, .provider:
            return .providedByEngine(engineNote(spec, prefix: prefix))
        case .unavailable:
            return .unavailable(spec.note ?? "Not available in this build.")
        case .installer:
            return installerState(spec, prefix: prefix)
        }
    }

    private func monoState() -> RuntimeComponentState {
        let mono = WindozMonoModel.shared
        switch mono.phase {
        case .downloading(let f): return .downloading(f)
        case .installing: return .installing
        case .idle: break
        }
        if WindozMonoModel.bundled { return .providedByEngine("Included in this build.") }
        if mono.installed { return .installed(nil) }
        if let error = mono.error { return .failed(error) }
        return .missing("Windoz downloads it from WineHQ — .NET Framework games need it.")
    }

    private func engineNote(_ spec: RuntimeSpec, prefix: PrefixManager) -> String {
        let base = spec.note ?? "Provided by the engine."
        let probes = spec.probeFiles.filter {
            FileManager.default.fileExists(atPath: prefix.url.appendingPathComponent($0).path)
        }
        guard !spec.probeFiles.isEmpty else { return base }
        if probes.isEmpty {
            return base + " (Not in the prefix yet — the engine stages it when the first session starts.)"
        }
        return "In place in this prefix. " + base
    }

    private func installerState(_ spec: RuntimeSpec, prefix: PrefixManager) -> RuntimeComponentState {
        let record = ledger.records[spec.id]
        // The prefix itself is the proof when it has the files.
        if let installedAt = record?.installedAt { return .installed(installedAt) }
        for probe in spec.probeFiles {
            if FileManager.default.fileExists(atPath: prefix.url.appendingPathComponent(probe).path) {
                return .installed(record?.ranAt)
            }
        }
        if let cache = cacheURL(spec), FileManager.default.fileExists(atPath: cache.path) {
            return .staged(cache.lastPathComponent)
        }
        if let ranAt = record?.ranAt { return .sessionRan(ranAt) }
        if let lastError = record?.lastError {
            if let next = record?.nextAttemptAt, next > Date() {
                return .failed("\(lastError) Windoz will wait until \(Self.time.string(from: next)) before trying again (backoff after a failure).")
            }
            return .failed(lastError)
        }
        return .missing(spec.detail)
    }

    // MARK: Downloading

    func download(_ spec: RuntimeSpec) {
        guard downloads[spec.id] == nil else { return }
        guard let urlString = spec.url, let url = URL(string: urlString) else {
            states[spec.id] = .failed("This build lists no official download for \(spec.title).")
            return
        }
        if let next = ledger.records[spec.id]?.nextAttemptAt, next > Date() {
            states[spec.id] = .failed("Backing off until \(Self.time.string(from: next)) after the last failure. Use Try again then.")
            return
        }
        do {
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        } catch {
            states[spec.id] = .failed("The download folder could not be created: \(error.localizedDescription)")
            return
        }
        states[spec.id] = .downloading(0)
        EngineLogStream.shared.append("[runtime] download \(spec.id) from \(url.absoluteString)")
        Task { await performDownload(spec: spec, url: url) }
    }

    func cancelDownload(_ spec: RuntimeSpec) {
        downloads[spec.id]?.cancel()
    }

    private func performDownload(spec: RuntimeSpec, url: URL) async {
        guard let destination = cacheURL(spec) else { return }
        let fm = FileManager.default

        // A verified cached file is the cheapest download: use it, or discard it.
        if fm.fileExists(atPath: destination.path) {
            do {
                try applyHashPolicy(file: destination, spec: spec, finalURL: ledger.records[spec.id]?.finalURL)
                states[spec.id] = .staged(destination.lastPathComponent)
                EngineLogStream.shared.append("[runtime] \(spec.id): a verified download is already cached.", level: .success)
                return
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                EngineLogStream.shared.append("[runtime] cached \(spec.id) refused: \(message)", level: .warning)
                try? fm.removeItem(at: destination)
            }
        }

        var attempt = 0
        while true {
            attempt += 1
            do {
                let temp = try await downloadFile(spec: spec, url: url)
                try? fm.removeItem(at: destination)
                try fm.moveItem(at: temp, to: destination)
                try applyHashPolicy(file: destination, spec: spec, finalURL: url.absoluteString)
                states[spec.id] = .staged(destination.lastPathComponent)
                EngineLogStream.shared.append("[runtime] \(spec.id): downloaded and verified (\(bytesDescription(destination))).", level: .success)
                return
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                if (error as? URLError)?.code == .cancelled {
                    // Cancelled by the user: no attempt, no backoff, no error row.
                    EngineLogStream.shared.append("[runtime] \(spec.id): download cancelled.")
                    if let prefix = prefixRef { states[spec.id] = state(for: spec, in: prefix) }
                    return
                }
                var record = ledger.records[spec.id] ?? RuntimeLedger.Record()
                record.attempts += 1
                record.lastError = message
                record.nextAttemptAt = Date().addingTimeInterval(Self.backoff(after: attempt))
                ledger.records[spec.id] = record
                persistLedger()
                EngineLogStream.shared.append("[runtime] \(spec.id) attempt \(attempt) failed: \(message)", level: .error)
                if attempt >= 3 {
                    states[spec.id] = .failed("\(message) Windoz tried three times; it will not retry automatically. Use Try again (after \(Self.time.string(from: Date().addingTimeInterval(Self.backoff(after: attempt))))).")
                    return
                }
                try? await Task.sleep(nanoseconds: UInt64(Self.backoff(after: attempt)) * 1_000_000_000)
            }
        }
    }

    /// 2 s after the first failure, 8 s after the second, then a five-minute
    /// cooling-off before the user may retry by hand.
    private static func backoff(after attempt: Int) -> TimeInterval {
        switch attempt {
        case 1: return 2
        case 2: return 8
        default: return 300
        }
    }

    private func downloadFile(spec: RuntimeSpec, url: URL) async throws -> URL {
        let stagingDir = staging
        let target = stagingDir.appendingPathComponent("\(spec.id).download")
        return try await withCheckedThrowingContinuation { continuation in
            let task = URLSession.shared.downloadTask(with: url) { temp, response, error in
                // The temporary file is removed when this returns: move it now,
                // and hop to the main actor only for the bookkeeping.
                Task { @MainActor in self.clearDownloadBookkeeping(spec) }
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let temp else {
                    continuation.resume(throwing: RuntimeInstallError.message("The download produced no file. \(spec.title) was not changed."))
                    return
                }
                if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                    continuation.resume(throwing: RuntimeInstallError.message("\(url.host ?? "The server") answered \(http.statusCode) for \(url.lastPathComponent)."))
                    return
                }
                do {
                    try? FileManager.default.removeItem(at: target)
                    try FileManager.default.moveItem(at: temp, to: target)
                } catch {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: target)
            }
            let observation = task.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
                let fraction = progress.fractionCompleted
                Task { @MainActor in
                    guard let self, case .downloading = self.states[spec.id] else { return }
                    self.states[spec.id] = .downloading(fraction)
                }
            }
            downloads[spec.id] = task
            observations[spec.id] = observation
            task.resume()
        }
    }

    private func clearDownloadBookkeeping(_ spec: RuntimeSpec) {
        observations[spec.id]?.invalidate()
        observations[spec.id] = nil
        downloads[spec.id] = nil
    }

    private func bytesDescription(_ url: URL) -> String {
        let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int64) ?? 0
        guard size > 0 else { return "size unknown" }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    // MARK: The hash contract

    /// Verifies the pinned hash, or the frozen first-download hash, and records
    /// the result in the prefix ledger. Throws — never warns — when the bytes
    /// changed; the message says exactly what happened and what the choices are.
    private func applyHashPolicy(file: URL, spec: RuntimeSpec, finalURL: String?) throws {
        let digest = try WindozMonoInstaller.sha256(of: file)
        if let pinned = spec.sha256?.lowercased() {
            guard digest == pinned else {
                throw RuntimeInstallError.message("The file \(URL(string: spec.url ?? "")?.lastPathComponent ?? spec.id) does not match the SHA-256 pinned in this build (\(pinned.prefix(12))… ≠ \(digest.prefix(12))…). Windoz refuses to install it: the vendor may have replaced the file. Install it yourself only if you have verified the new file.")
            }
        } else if let recorded = ledger.records[spec.id]?.recordedSHA256?.lowercased(), recorded != digest {
            throw RuntimeInstallError.message("The file at \(spec.url ?? "the vendor's link") changed since Windoz first downloaded it (\(recorded.prefix(12))… → \(digest.prefix(12))…). Windoz will not silently install new bytes. Use \"Accept the vendor's new file\" to update the record if you trust the change.")
        }
        var record = ledger.records[spec.id] ?? RuntimeLedger.Record()
        record.recordedSHA256 = digest
        record.finalURL = finalURL ?? spec.url
        let size = ((try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? Int64)
        record.bytes = size ?? spec.bytes
        record.downloadedAt = Date()
        record.attempts = 0
        record.lastError = nil
        record.nextAttemptAt = nil
        ledger.records[spec.id] = record
        persistLedger()
    }

    /// "Accept the vendor's new file": forgets the frozen hash and the cache so
    /// the next download records the vendor's current bytes. Explicit on
    /// purpose — the user decides, Windoz does not.
    func acceptNewFile(_ spec: RuntimeSpec) {
        if let cache = cacheURL(spec) { try? FileManager.default.removeItem(at: cache) }
        var record = ledger.records[spec.id] ?? RuntimeLedger.Record()
        record.recordedSHA256 = nil
        record.downloadedAt = nil
        record.lastError = nil
        record.nextAttemptAt = nil
        ledger.records[spec.id] = record
        persistLedger()
        if let prefix = prefixRef { states[spec.id] = state(for: spec, in: prefix) }
        EngineLogStream.shared.append("[runtime] \(spec.id): the recorded vendor hash was cleared at the user's request.")
    }

    func removeDownload(_ spec: RuntimeSpec) {
        if let cache = cacheURL(spec) { try? FileManager.default.removeItem(at: cache) }
        if let prefix = prefixRef { states[spec.id] = state(for: spec, in: prefix) }
    }

    func cacheExists(_ spec: RuntimeSpec) -> Bool {
        guard let cache = cacheURL(spec) else { return false }
        return FileManager.default.fileExists(atPath: cache.path)
    }

    /// When a game's own one-time installer (`GameRedistItem.ledgerKey`) was
    /// handed to a session — the game page's card reads it.
    func recordedRedistRun(key: String) -> Date? { ledger.records[key]?.ranAt }

    /// True when this entry has no pinned hash but the ledger holds a frozen
    /// first-download hash — the one case "Accept the vendor's new file" applies.
    func hasFrozenHash(_ spec: RuntimeSpec) -> Bool {
        spec.sha256 == nil && ledger.records[spec.id]?.recordedSHA256 != nil
    }

    /// Forgets the ledger record (keeps a verified download).
    func forget(_ spec: RuntimeSpec) {
        ledger.records[spec.id] = nil
        persistLedger()
        if let prefix = prefixRef { states[spec.id] = state(for: spec, in: prefix) }
        EngineLogStream.shared.append("[runtime] \(spec.id): the record was forgotten at the user's request.")
    }

    /// "Reinstall…": forgets both the record and the cached download, so the
    /// next attempt starts clean.
    func resetRow(_ spec: RuntimeSpec) {
        if let cache = cacheURL(spec) { try? FileManager.default.removeItem(at: cache) }
        ledger.records[spec.id] = nil
        persistLedger()
        if let prefix = prefixRef { states[spec.id] = state(for: spec, in: prefix) }
        EngineLogStream.shared.append("[runtime] \(spec.id): the record and download were reset at the user's request.")
    }

    private func cacheURL(_ spec: RuntimeSpec) -> URL? {
        guard let urlString = spec.url, let parsed = URL(string: urlString) else { return nil }
        let name = parsed.lastPathComponent.isEmpty ? "\(spec.id).exe" : parsed.lastPathComponent
        return staging.appendingPathComponent("\(spec.id)-\(name)")
    }

    private func persistLedger() {
        guard let ledgerURL else { return }
        ledger.save(to: ledgerURL)
    }

    // MARK: Installer sessions

    /// Runs the vendor's own installer in a real Windows session. Windoz allows
    /// one session per launch of the app, so the row says what that means.
    func startInstallSession(_ spec: RuntimeSpec, using engine: WindozEngine) {
        switch spec.kind {
        case .mono:
            WindozMonoModel.shared.install()
        case .installer:
            guard wine_process_is_running() == 0 else {
                states[spec.id] = .failed("A Windows session is already running. Windoz runs one at a time — try again after it ends.")
                return
            }
            guard case .staged = states[spec.id] ?? .unknown, let cache = cacheURL(spec),
                  FileManager.default.fileExists(atPath: cache.path) else {
                states[spec.id] = .failed("Install \(spec.title) by downloading it first.")
                return
            }
            startInstallSession(file: cache, argsText: spec.installArgs, title: spec.title,
                                ledgerKey: spec.id, using: engine)
        default:
            break
        }
    }

    /// The same session path for a game's own one-time installer
    /// (`_CommonRedist`), which has no catalog entry.
    func startInstallSession(file: URL, argsText: String?, title: String,
                             ledgerKey: String?, using engine: WindozEngine) {        guard wine_process_is_running() == 0 else {
            report(ledgerKey, "A Windows session is already running. Windoz runs one at a time — try again after it ends.")
            return
        }
        do {
            let game = try prepareInstallSession(file: file, argsText: argsText, title: title)
            if let ledgerKey {
                var record = ledger.records[ledgerKey] ?? RuntimeLedger.Record()
                record.ranAt = Date()
                record.lastError = nil
                ledger.records[ledgerKey] = record
                persistLedger()
                states[ledgerKey] = .installing
            }
            Task {
                do {
                    try await engine.launch(game)
                    EngineLogStream.shared.append("[runtime] installer session started: \(title)")
                } catch {
                    let text = Self.installLaunchFailureText(error, title: title)
                    self.report(ledgerKey, text)
                }
            }
        } catch {
            let text = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            report(ledgerKey, text)
        }
    }

    private func report(_ ledgerKey: String?, _ message: String) {
        EngineLogStream.shared.append("[runtime] \(message)", level: .error)
        if let ledgerKey {
            var record = ledger.records[ledgerKey] ?? RuntimeLedger.Record()
            record.lastError = message
            ledger.records[ledgerKey] = record
            persistLedger()
            states[ledgerKey] = .failed(message)
        }
    }

    private static func installLaunchFailureText(_ error: Error, title: String) -> String {
        if let engineError = error as? EngineError {
            switch engineError {
            case .sessionAlreadyRanThisRun:
                return "Windoz already ran its one Windows session for this launch of the app. Quit Windoz (swipe it away) and reopen it, then install \(title)."
            case .sessionAlreadyRunning:
                return "A Windows session is already running. Try again after it ends."
            case .jitRequired:
                return "JIT must be enabled before a session can run. Open Settings › JIT setup first."
            default:
                break
            }
        }
        return "\(title) could not start: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
    }

    /// Copies the installer into the prefix (drive_c/windoz-runtimes) and builds
    /// the synthetic game the normal launch pipeline runs it as.
    private func prepareInstallSession(file: URL, argsText: String?, title: String) throws -> InstalledGame {
        guard let prefix = prefixRef else {
            throw RuntimeInstallError.message("The Windows environment is not ready yet. Open Settings once, then try again.")
        }
        let directory = prefix.url.appendingPathComponent("drive_c/windoz-runtimes", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw RuntimeInstallError.message("The prefix refused the installer file: \(error.localizedDescription)")
        }
        let destination = directory.appendingPathComponent(file.lastPathComponent)
        try? FileManager.default.removeItem(at: destination)
        do {
            try FileManager.default.copyItem(at: file, to: destination)
        } catch {
            throw RuntimeInstallError.message("The installer could not be copied into the prefix: \(error.localizedDescription)")
        }
        var game = InstalledGame(title: "Installing \(title)", executablePath: destination.path)
        game.workingDirectory = directory.path
        game.settings.launchMode = .direct
        game.settings.launchArguments = argsText ?? ""
        return game
    }

    // MARK: Launch pipeline

    /// One line for the launch pipeline's runtimes step, or nil when there is
    /// nothing to say. Nothing here blocks a launch: offline is allowed, and
    /// the game starts anyway.
    func launchNotice(prefix: PrefixManager) -> String? {
        if let manifestProblem {
            return "The runtime manifest is missing from this build — \(manifestProblem)"
        }
        refresh(prefix: prefix)
        var pending: [String] = []
        for spec in specs {
            switch spec.kind {
            case .mono:
                if case .installed = states[spec.id] ?? .unknown { continue }
                if case .providedByEngine = states[spec.id] ?? .unknown { continue }
                pending.append("Wine Mono (needed only by .NET Framework games)")
            case .installer:
                switch states[spec.id] ?? .unknown {
                case .installed, .providedByEngine: continue
                case .staged: pending.append("\(spec.title) (downloaded; tap Install in Settings › Windows runtimes)")
                case .sessionRan: pending.append("\(spec.title) (ran, not confirmed)") 
                default: pending.append("\(spec.title) (not downloaded)")
                }
            default:
                continue
            }
        }
        guard !pending.isEmpty else { return nil }
        let shown = pending.prefix(3).joined(separator: ", ")
        let more = pending.count > 3 ? " and \(pending.count - 3) more" : ""
        return "Not set up yet: \(shown)\(more) — Settings › Windows runtimes. The game starts anyway."
    }

    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()
}

// MARK: - Row UI

/// One row of Settings › Windows runtimes (also used by the setup screen).
/// It reads the installer and the Wine Mono model directly so every state —
/// download progress, backoff, session running — is live.
struct RuntimeRowView: View {
    let spec: RuntimeSpec

    @ObservedObject private var installer = RuntimeInstaller.shared
    @ObservedObject private var mono = WindozMonoModel.shared
    @EnvironmentObject private var engine: WindozEngine
    @State private var confirmMonoRemove = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(spec.title).font(.subheadline.weight(.medium))
                Spacer(minLength: 8)
                badge
            }
            if spec.kind == .mono {
                monoRow
            } else {
                detailText
            }
        }
        .padding(.vertical, 2)
        .confirmationDialog("Remove Wine Mono?", isPresented: $confirmMonoRemove, titleVisibility: .visible) {
            Button("Remove", role: .destructive) { mono.remove() }
        } message: {
            Text(".NET Framework games will not start until you download it again.")
        }
    }

    // MARK: Mono branch

    @ViewBuilder private var monoRow: some View {
        Text(mono.status).font(.caption).foregroundStyle(.secondary)
        if case .downloading(let f) = mono.phase { ProgressView(value: f) }
        if case .installing(let f) = mono.phase { ProgressView(value: f) }
        if let error = mono.error {
            Text(error).font(.caption).foregroundStyle(.red)
        }
        if !WindozMonoModel.bundled && !mono.busy {
            if mono.installed {
                Button("Remove Wine Mono", role: .destructive) { confirmMonoRemove = true }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            } else {
                Button {
                    mono.install()
                } label: {
                    Label(mono.error == nil ? "Download Wine Mono" : "Try again", systemImage: "arrow.down.circle")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        if let note = spec.note {
            Text(note).font(.caption2).foregroundStyle(.secondary)
        }
    }

    // MARK: Non-mono branch

    private var state: RuntimeComponentState { installer.states[spec.id] ?? .unknown }

    @ViewBuilder private var detailText: some View {
        switch state {
        case .providedByEngine(let note):
            Text(note).font(.caption).foregroundStyle(.secondary)
        case .unavailable(let reason):
            Text(reason).font(.caption).foregroundStyle(.secondary)
        case .missing(let detail):
            Text(detail).font(.caption).foregroundStyle(.secondary)
            if let note = spec.note {
                Text(note).font(.caption2).foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                if let urlString = spec.url, let url = URL(string: urlString) {
                    Button {
                        installer.download(spec)
                    } label: {
                        Label("Download", systemImage: "arrow.down.circle")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    Link(destination: url) {
                        Text("Open the vendor's page").font(.caption)
                    }
                }
            }
        case .downloading(let f):
            Text(spec.detail).font(.caption).foregroundStyle(.secondary)
            ProgressView(value: f)
            HStack(spacing: 10) {
                Text("\(Int((f * 100).rounded()))%").font(.caption2).foregroundStyle(.secondary)
                Button("Cancel") { installer.cancelDownload(spec) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        case .staged(let name):
            Text("Downloaded and verified: \(name)").font(.caption).foregroundStyle(.secondary)
            if let note = spec.note {
                Text(note).font(.caption2).foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                Button {
                    installer.startInstallSession(spec, using: engine)
                } label: {
                    Label("Install in a Windows session", systemImage: "play.circle")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                Button("Delete download") { installer.removeDownload(spec) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        case .installing:
            Text("A Windows session is running the installer. Windoz allows one session per launch of the app — after it ends, quit and reopen Windoz to play.")
                .font(.caption).foregroundStyle(.secondary)
        case .sessionRan(let date):
            Text("Ran on \(Self.day.string(from: date)). Windoz could not confirm from the prefix files what it left behind — check the game, or run it again.")
                .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                if installer.cacheExists(spec) {
                    Button("Run again") { installer.startInstallSession(spec, using: engine) }
                        .buttonStyle(.bordered).controlSize(.small)
                }
                Button("Forget record") { installer.forget(spec) }
                    .buttonStyle(.bordered).controlSize(.small)
            }
        case .installed(let date):
            Text(date.map { "Installed (confirmed in the prefix on \(Self.day.string(from: $0)))." } ?? "Installed.")
                .font(.caption).foregroundStyle(.green)
            if let note = spec.note {
                Text(note).font(.caption2).foregroundStyle(.secondary)
            }
        case .failed(let message):
            Text(message).font(.caption).foregroundStyle(.red)
            HStack(spacing: 10) {
                if spec.url != nil {
                    Button("Try again") { installer.download(spec) }
                        .buttonStyle(.bordered).controlSize(.small)
                }
                if installer.hasFrozenHash(spec) {
                    Button("Accept the vendor's new file") { installer.acceptNewFile(spec) }
                        .buttonStyle(.bordered).controlSize(.small)
                }
                Button("Reinstall…") { installer.resetRow(spec) }
                    .buttonStyle(.bordered).controlSize(.small)
            }
        case .unknown:
            Text(spec.detail).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var badgeState: RuntimeComponentState {
        guard spec.kind == .mono else { return state }
        if WindozMonoModel.bundled { return .providedByEngine("") }
        if mono.busy { return .installing }
        if mono.installed { return .installed(nil) }
        return .missing(spec.detail)
    }

    @ViewBuilder private var badge: some View {
        switch badgeState {
        case .providedByEngine:
            Text("Engine").badgeLike(.green)
        case .installed:
            Text("Installed").badgeLike(.green)
        case .unavailable:
            Text("Not in this build").badgeLike(.gray)
        case .missing:
            Text(spec.url == nil ? "—" : "Not downloaded").badgeLike(.orange)
        case .downloading:
            Text("Downloading").badgeLike(.blue)
        case .staged:
            Text("Downloaded").badgeLike(.blue)
        case .installing:
            Text("Session running").badgeLike(.blue)
        case .sessionRan:
            Text("Ran").badgeLike(.orange)
        case .failed:
            Text("Failed").badgeLike(.red)
        case .unknown:
            Text("—").badgeLike(.gray)
        }
    }

    private static let day: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()
}

private extension Text {
    func badgeLike(_ color: Color) -> some View {
        self.font(.caption2.weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }
}
