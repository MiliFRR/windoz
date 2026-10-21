import Foundation
import CryptoKit
import Network
import UIKit

/// One queued download. Value type so the UI can diff and render cheaply.
struct DownloadItem: Identifiable, Equatable {
    enum State: Equatable {
        case queued
        case downloading
        case paused
        case verifying
        case completed
        case failed(String)

        var isTerminal: Bool {
            switch self { case .completed, .failed: return true; default: return false }
        }
    }

    var id = UUID()
    var title: String
    var remoteURL: URL
    var destination: URL
    var expectedSHA256: String?
    var totalBytes: Int64 = 0
    var receivedBytes: Int64 = 0
    var state: State = .queued
    var startedAt: Date?
    var bytesPerSecond: Double = 0
    var etaSeconds: Double = 0
    /// Provider this download belongs to ("steam", "epic", ...).
    var storeID: String = ""

    var progress: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1, Double(receivedBytes) / Double(totalBytes))
    }
}

/// A queue of resumable file downloads with free-space checks, an optional
/// Wi-Fi-only rule and SHA-256 verification. Real `URLSession` transfers, with
/// `resumeData` so a pause survives a relaunch (the data is persisted).
final class DownloadManager: NSObject, ObservableObject {
    static let shared = DownloadManager()

    @Published private(set) var items: [DownloadItem] = []
    @Published var wifiOnly: Bool
    @Published private(set) var onExpensiveConnection: Bool = false

    /// iOS hands a background `URLSession` back to the app when a transfer
    /// finishes, even after the process was suspended or killed. The identifier
    /// is per install and must not contain a slash. LiveContainer cannot host
    /// a guest background session, so that path stays on the in-process queue.
    static var backgroundSessionIdentifier: String { AppEnvironment.bundleIdentifier + ".background-downloads" }

    private var session: URLSession!
    private let usesBackgroundSession: Bool
    private var activeTask: [UUID: URLSessionDownloadTask] = [:]
    private var resumeData: [UUID: Data] = [:]
    private var maxConcurrent = 2
    private let pathMonitor = NWPathMonitor()
    private let persistenceURL: URL
    private let legacyPersistenceURL: URL
    private var restored = false
    private lazy var stagingDirectory: URL = {
        let preferred = AppContainer.storageRoot.appendingPathComponent("windoz-staging", isDirectory: true)
        if (try? FileManager.default.createDirectory(at: preferred, withIntermediateDirectories: true)) != nil {
            return preferred
        }
        let fallback = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("windoz-staging", isDirectory: true)
        try? FileManager.default.createDirectory(at: fallback, withIntermediateDirectories: true)
        return fallback
    }()

    private override init() {
        wifiOnly = UserDefaults.standard.bool(forKey: "windoz.downloads.wifiOnly")
        persistenceURL = AppContainer.storageRoot.appendingPathComponent("windoz-downloads.json")
        legacyPersistenceURL = AppContainer.downloadsFile

        // A background session is the only kind iOS keeps moving network
        // traffic for after the app leaves the foreground. Inside
        // LiveContainer the guest cannot register one, so the queue there
        // stays a foreground session and the UI says so.
        let config: URLSessionConfiguration
        if AppEnvironment.isLiveContainer {
            usesBackgroundSession = false
            config = URLSessionConfiguration.default
        } else {
            usesBackgroundSession = true
            config = URLSessionConfiguration.background(withIdentifier: Self.backgroundSessionIdentifier)
            config.sessionSendsLaunchEvents = true
            config.isDiscretionary = false
        }
        config.waitsForConnectivity = true
        config.allowsExpensiveNetworkAccess = true
        config.allowsConstrainedNetworkAccess = true
        config.httpMaximumConnectionsPerHost = 4

        super.init()
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)

        pathMonitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                self?.onExpensiveConnection = path.isExpensive
                self?.pump()
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "windoz.netpath"))
        restore()
    }

    // MARK: - Queue control

    /// The Wi-Fi-only rule, persisted so it survives a relaunch.
    func setWifiOnly(_ value: Bool) {
        guard wifiOnly != value else { return }
        wifiOnly = value
        UserDefaults.standard.set(value, forKey: "windoz.downloads.wifiOnly")
        pump()
    }

    @discardableResult
    func enqueue(title: String, url: URL, destination: URL, sha256: String? = nil, storeID: String = "") -> UUID? {
        // Free-space check: we need the bytes we have left to fetch, plus slack.
        if let size = Self.remoteSize(of: url) {
            let available = WindozEngine.freeStorageBytes()
            if size > available {
                let needed = ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
                let have = ByteCountFormatter.string(fromByteCount: available, countStyle: .file)
                items.append(DownloadItem(title: title, remoteURL: url, destination: destination,
                                          expectedSHA256: sha256, state: .failed("Not enough free space: needs \(needed), \(have) free."),
                                          storeID: storeID))
                return nil
            }
        }
        let item = DownloadItem(title: title, remoteURL: url, destination: destination,
                                expectedSHA256: sha256, storeID: storeID)
        items.append(item)
        persist()
        pump()
        return item.id
    }

    func pause(_ id: UUID) {
        guard let task = activeTask[id] else {
            setState(id, .paused)
            return
        }
        task.cancel(byProducingResumeData: { [weak self] data in
            DispatchQueue.main.async {
                guard let self else { return }
                self.resumeData[id] = data
                self.activeTask[id] = nil
                self.setState(id, .paused)
                self.persist()
            }
        })
    }

    func resume(_ id: UUID) {
        guard let index = index(of: id), case .paused = items[index].state else { return }
        items[index].state = .queued
        pump()
    }

    func cancel(_ id: UUID) {
        if let task = activeTask[id] {
            activeTask[id] = nil
            task.cancel()
        }
        resumeData[id] = nil
        remove(id)
    }

    func removeCompleted() {
        items.removeAll { $0.state == .completed }
        persist()
    }

    func clearCompletedAndFailed() {
        items.removeAll { $0.state.isTerminal }
        persist()
    }

    // MARK: - Pump

    private func pump() {
        let active = items.filter { $0.state == .downloading }.count
        guard active < maxConcurrent else { return }
        if wifiOnly && onExpensiveConnection { return }

        for item in items where item.state == .queued {
            start(item)
            if items.filter({ $0.state == .downloading }).count >= maxConcurrent { break }
        }
    }

    private func start(_ item: DownloadItem) {
        try? FileManager.default.createDirectory(at: item.destination.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        let task: URLSessionDownloadTask
        if let data = resumeData[item.id] {
            task = session.downloadTask(withResumeData: data)
            resumeData[item.id] = nil
        } else {
            task = session.downloadTask(with: item.remoteURL)
        }
        // A background task outlives this process. The UUID in taskDescription
        // is what lets the delegate find the queue item again after a relaunch.
        task.taskDescription = item.id.uuidString
        activeTask[item.id] = task
        setState(item.id, .downloading, started: true)
        task.resume()
    }

    // MARK: - Background hand-off

    /// After a relaunch iOS reconnects the existing background tasks to the
    /// new session. Walk them once so the UI shows real progress and Pause /
    /// Cancel still have a task to talk to. `taskDescription` survives the
    /// process, unlike task identifiers.
    private func reattachBackgroundTasks() {
        guard usesBackgroundSession else { return }
        session.getAllTasks { [weak self] tasks in
            DispatchQueue.main.async {
                guard let self else { return }
                for task in tasks {
                    guard let id = self.itemID(for: task),
                          let download = task as? URLSessionDownloadTask else { continue }
                    self.activeTask[id] = download
                    if let index = self.index(of: id), !self.items[index].state.isTerminal {
                        self.items[index].state = .downloading
                        self.items[index].startedAt = self.items[index].startedAt ?? Date()
                    }
                }
                if !tasks.isEmpty {
                    EngineLogStream.shared.append("[downloads] reattached to \(tasks.count) background transfer(s) after launch.")
                }
                self.persist()
                self.pump()
            }
        }
    }

    private func itemID(for task: URLSessionTask) -> UUID? {
        guard let raw = task.taskDescription, let id = UUID(uuidString: raw),
              index(of: id) != nil else { return nil }
        return id
    }

    /// Move the system's temporary file somewhere this app controls while the
    /// delegate callback still guarantees it exists. Reading the destination
    /// record must happen on the main queue, but the temp file may be deleted
    /// as soon as this delegate returns.
    private func stage(_ location: URL) -> URL? {
        let target = stagingDirectory.appendingPathComponent(UUID().uuidString + ".download")
        do {
            try FileManager.default.moveItem(at: location, to: target)
            return target
        } catch {
            do {
                try FileManager.default.copyItem(at: location, to: target)
                return target
            } catch {
                EngineLogStream.shared.append("[downloads] the finished transfer could not be staged: \(error.localizedDescription)", level: .error)
                return nil
            }
        }
    }

    // MARK: - Helpers

    private func index(of id: UUID) -> Int? { items.firstIndex { $0.id == id } }

    private func setState(_ id: UUID, _ state: DownloadItem.State, started: Bool = false) {
        guard let i = index(of: id) else { return }
        items[i].state = state
        if started { items[i].startedAt = items[i].startedAt ?? Date() }
        persist()
    }

    private func remove(_ id: UUID) {
        items.removeAll { $0.id == id }
        persist()
    }

    private static func remoteSize(of url: URL) -> Int64? {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        // A synchronous HEAD is acceptable here: it is a queue-time free-space check.
        let semaphore = DispatchSemaphore(value: 0)
        var size: Int64?
        URLSession.shared.dataTask(with: request) { _, response, _ in
            size = (response as? HTTPURLResponse)?.expectedContentLength
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + 5)
        return (size ?? 0) > 0 ? size : nil
    }

    private func verify(_ item: DownloadItem, at url: URL) -> String? {
        guard let expected = item.expectedSHA256?.lowercased() else { return nil }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "the file could not be read for verification" }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return digest == expected ? nil : "the file's SHA-256 did not match (expected \(expected.prefix(12))…, got \(digest.prefix(12))…)"
    }

    // MARK: - Persistence

    private struct PersistedItem: Codable {
        var title: String
        var remoteURL: URL
        var destination: URL
        var expectedSHA256: String?
        var totalBytes: Int64
        var receivedBytes: Int64
        var storeID: String
    }

    private func persist() {
        let snapshot = items.filter { !$0.state.isTerminal }.map {
            PersistedItem(title: $0.title, remoteURL: $0.remoteURL, destination: $0.destination,
                          expectedSHA256: $0.expectedSHA256, totalBytes: $0.totalBytes,
                          receivedBytes: $0.receivedBytes, storeID: $0.storeID)
        }
        if let data = try? JSONEncoder().encode(snapshot) {
            var written = Set<String>()
            for url in [persistenceURL, legacyPersistenceURL] where written.insert(url.standardizedFileURL.path).inserted {
                do {
                    try data.write(to: url, options: .atomic)
                    return
                } catch {
                    if ContainerFS.writeFile(url.path, data).ok { return }
                }
            }
            EngineLogStream.shared.append("[downloads] the resume list could not be saved anywhere this device allows", level: .warning)
        }
    }

    func restore() {
        guard !restored else { return }
        restored = true
        defer { reattachBackgroundTasks() }

        var saved: [PersistedItem]?
        for url in [persistenceURL, legacyPersistenceURL] {
            if let data = try? Data(contentsOf: url),
               let decoded = try? JSONDecoder().decode([PersistedItem].self, from: data) {
                saved = decoded
                break
            }
        }
        guard let saved else { return }
        for s in saved where !items.contains(where: { $0.destination == s.destination }) {
            items.append(DownloadItem(title: s.title, remoteURL: s.remoteURL, destination: s.destination,
                                      expectedSHA256: s.expectedSHA256, totalBytes: s.totalBytes,
                                      receivedBytes: s.receivedBytes, state: .paused, storeID: s.storeID))
        }
    }
}

extension DownloadManager: URLSessionDownloadDelegate {

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard let id = itemID(for: downloadTask) else { return }
        DispatchQueue.main.async {
            guard let i = self.index(of: id) else { return }
            if self.items[i].state == .paused || self.items[i].state == .queued {
                self.items[i].state = .downloading
                self.items[i].startedAt = self.items[i].startedAt ?? Date()
            }
            self.items[i].receivedBytes = totalBytesWritten
            if totalBytesExpectedToWrite > 0 { self.items[i].totalBytes = totalBytesExpectedToWrite }
            if let started = self.items[i].startedAt {
                let elapsed = Date().timeIntervalSince(started)
                if elapsed > 0.5 {
                    self.items[i].bytesPerSecond = Double(totalBytesWritten) / elapsed
                    let remaining = Double(self.items[i].totalBytes - totalBytesWritten)
                    if self.items[i].bytesPerSecond > 0 {
                        self.items[i].etaSeconds = remaining / self.items[i].bytesPerSecond
                    }
                }
            }
            DownloadActivity.shared.update(for: self.items[i])
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        guard let id = itemID(for: downloadTask) else {
            // A transfer from a session that no longer has a queue record:
            // do not leave the system's temp file behind.
            try? FileManager.default.removeItem(at: location)
            EngineLogStream.shared.append("[downloads] an unclaimed background transfer finished; its temp file was removed.", level: .warning)
            return
        }
        guard let staged = stage(location) else {
            DispatchQueue.main.async {
                self.activeTask[id] = nil
                self.setState(id, .failed("the finished download could not be staged for saving."))
                self.pump()
            }
            return
        }
        DispatchQueue.main.async {
            self.activeTask[id] = nil
            self.finishDownload(id: id, staged: staged)
        }
    }

    /// Main-thread half of a finished transfer: move the staged file into the
    /// queue's destination, verify its hash, and start the next item.
    private func finishDownload(id: UUID, staged: URL) {
        guard let i = index(of: id) else {
            try? FileManager.default.removeItem(at: staged)
            return
        }
        let item = items[i]
        let destination = item.destination

        do {
            try FileManager.default.removeItem(at: destination)
        } catch {
            if FileManager.default.fileExists(atPath: destination.path) {
                let raw = error as NSError
                EngineLogStream.shared.append("[downloads] could not clear the previous \(destination.lastPathComponent): \(raw.domain) \(raw.code) - \(raw.localizedDescription)", level: .warning)
            }
        }

        var saved = false
        do {
            try FileManager.default.moveItem(at: staged, to: destination)
            saved = true
        } catch {
            let raw = error as NSError
            EngineLogStream.shared.append("[downloads] move failed for \(destination.lastPathComponent): \(raw.domain) \(raw.code) - \(raw.localizedDescription)", level: .warning)
        }
        if !saved {
            do {
                try FileManager.default.copyItem(at: staged, to: destination)
                saved = true
            } catch {
                let raw = error as NSError
                EngineLogStream.shared.append("[downloads] copy fallback failed: \(raw.domain) \(raw.code) - \(raw.localizedDescription)", level: .warning)
            }
        }
        if !saved, let data = try? Data(contentsOf: staged) {
            let result = ContainerFS.writeFile(destination.path, data)
            if result.ok {
                saved = true
                EngineLogStream.shared.append("[downloads] saved via the C library: \(destination.lastPathComponent)")
            } else {
                EngineLogStream.shared.append("[downloads] C-library write refused: \(result.detail)", level: .error)
            }
        }
        if saved {
            try? FileManager.default.removeItem(at: staged)
        } else {
            EngineLogStream.shared.append("[downloads] \(destination.lastPathComponent) could not be saved by any route", level: .error)
            setState(id, .failed("the downloaded file could not be saved - every route was refused, and the log names each errno."))
            pump()
            return
        }

        items[i].state = .verifying
        if let problem = verify(item, at: destination) {
            setState(id, .failed(problem))
        } else {
            setState(id, .completed)
            DownloadActivity.shared.finish(for: id)
        }
        persist()
        pump()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        guard let id = itemID(for: task) else { return }
        DispatchQueue.main.async {
            self.activeTask[id] = nil
            if let resume = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
                self.resumeData[id] = resume
                self.setState(id, .paused)
            } else {
                self.setState(id, .failed(error.localizedDescription))
            }
            self.pump()
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in
            let handler = WindozAppDelegate.backgroundCompletionHandler
            WindozAppDelegate.backgroundCompletionHandler = nil
            handler?()
        }
    }
}
