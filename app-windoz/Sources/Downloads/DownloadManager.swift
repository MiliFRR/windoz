import Foundation
import CryptoKit
import Network
import BackgroundTasks

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

    /// iOS 26 continued-processing identifier; must be prefixed with the *live*
    /// bundle id, which differs from the build-time one after a re-sign.
    static var backgroundTaskIdentifier: String { AppEnvironment.bundleIdentifier + ".download" }

    private var session: URLSession!
    private var taskToItem: [Int: UUID] = [:]
    private var activeTask: [UUID: URLSessionDownloadTask] = [:]
    private var resumeData: [UUID: Data] = [:]
    private var maxConcurrent = 2
    private let pathMonitor = NWPathMonitor()
    private let persistenceURL: URL

    private override init() {
        wifiOnly = UserDefaults.standard.bool(forKey: "windoz.downloads.wifiOnly")
        persistenceURL = AppContainer.downloadsFile
        super.init()
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = true
        config.allowsExpensiveNetworkAccess = true
        config.allowsConstrainedNetworkAccess = true
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)

        pathMonitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                self?.onExpensiveConnection = path.isExpensive
                self?.pump()
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "windoz.netpath"))
        registerBackgroundTask()
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
                self.taskToItem[task.taskIdentifier] = nil
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
            taskToItem[task.taskIdentifier] = nil
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
        taskToItem[task.taskIdentifier] = item.id
        activeTask[item.id] = task
        setState(item.id, .downloading, started: true)
        task.resume()
        beginBackgroundContinuation()
    }

    // MARK: - Background continuation

    /// Whether `BGTaskScheduler` accepts this app's identifier. Registering an
    /// identifier that is not listed in `BGTaskSchedulerPermittedIdentifiers`
    /// raises an uncatchable exception, and the live bundle id is not the
    /// build-time one after a re-sign, so the list is read back first.
    private var backgroundTaskPermitted = false

    private func registerBackgroundTask() {
        if AppEnvironment.isLiveContainer {
            EngineLogStream.shared.append("Continued downloads in the background are unavailable inside LiveContainer (guest apps cannot register BGTaskScheduler identifiers). Keep Windoz open while a download runs.", level: .warning)
            return
        }
        let identifier = Self.backgroundTaskIdentifier
        let permitted = Bundle.main.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") as? [String] ?? []
        guard permitted.contains(identifier) else {
            EngineLogStream.shared.append("Continued downloads in the background are unavailable: \(identifier) is not one of this build's permitted background-task identifiers, so a transfer is paused while Windoz is closed.", level: .warning)
            return
        }
        backgroundTaskPermitted = true
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { [weak self] task in
            self?.scheduleBackgroundContinuation()
            self?.pump()
            task.setTaskCompleted(success: true)
        }
    }

    private func beginBackgroundContinuation() {
        guard backgroundTaskPermitted else { return }
        scheduleBackgroundContinuation()
    }

    private func scheduleBackgroundContinuation() {
        guard backgroundTaskPermitted else { return }
        let request = BGProcessingTaskRequest(identifier: Self.backgroundTaskIdentifier)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        request.earliestBeginDate = Date(timeIntervalSinceNow: 1)
        try? BGTaskScheduler.shared.submit(request)
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
            try? data.write(to: persistenceURL, options: .atomic)
        }
    }

    func restore() {
        guard let data = try? Data(contentsOf: persistenceURL),
              let saved = try? JSONDecoder().decode([PersistedItem].self, from: data) else { return }
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
        DispatchQueue.main.async {
            guard let id = self.taskToItem[downloadTask.taskIdentifier], let i = self.index(of: id) else { return }
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
        let id = taskToItem[downloadTask.taskIdentifier]
        taskToItem[downloadTask.taskIdentifier] = nil
        if let id { activeTask[id] = nil }
        guard let id, let i = index(of: id) else { return }
        let item = items[i]

        // Move out of the temp location synchronously.
        do {
            try FileManager.default.removeItem(at: item.destination)
        } catch {
            if FileManager.default.fileExists(atPath: item.destination.path) {
                let raw = error as NSError
                EngineLogStream.shared.append("[downloads] could not clear the previous \(item.destination.lastPathComponent): \(raw.domain) \(raw.code) — \(raw.localizedDescription)", level: .warning)
            }
        }
        var saved = false
        do {
            try FileManager.default.moveItem(at: location, to: item.destination)
            saved = true
        } catch {
            // Device test, 2026-10-17: moving CFNetwork's temp file into the
            // container answered "you don't have permission". Fall back to a
            // plain copy through Data, then to the C library's raw write.
            let raw = error as NSError
            EngineLogStream.shared.append("[downloads] move failed for \(item.destination.lastPathComponent): \(raw.domain) \(raw.code) — \(raw.localizedDescription)", level: .warning)
        }
        if !saved {
            do {
                let data = try Data(contentsOf: location)
                try data.write(to: item.destination)
                saved = true
            } catch {
                let raw = error as NSError
                EngineLogStream.shared.append("[downloads] copy fallback failed: \(raw.domain) \(raw.code) — \(raw.localizedDescription)", level: .warning)
            }
        }
        if !saved, let data = try? Data(contentsOf: location) {
            let result = ContainerFS.writeFile(item.destination.path, data)
            if result.ok {
                saved = true
                EngineLogStream.shared.append("[downloads] saved via the C library: \(item.destination.lastPathComponent)")
            } else {
                EngineLogStream.shared.append("[downloads] C-library write refused: \(result.detail)", level: .error)
            }
        }
        if saved {
            try? FileManager.default.removeItem(at: location)
        } else {
            EngineLogStream.shared.append("[downloads] \(item.destination.lastPathComponent) could not be saved by any route", level: .error)
            DispatchQueue.main.async {
                self.setState(id, .failed("the downloaded file could not be saved — every route was refused, and the log names each errno."))
            }
            return
        }

        DispatchQueue.main.async {
            self.items[i].state = .verifying
            if let problem = self.verify(item, at: item.destination) {
                self.setState(id, .failed(problem))
            } else {
                self.setState(id, .completed)
                DownloadActivity.shared.finish(for: id)
            }
            self.persist()
            self.pump()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        let id = taskToItem[task.taskIdentifier]
        taskToItem[task.taskIdentifier] = nil
        if let id { activeTask[id] = nil }
        guard let id else { return }
        DispatchQueue.main.async {
            if let resume = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
                self.resumeData[id] = resume
                self.setState(id, .paused)
            } else {
                self.setState(id, .failed(error.localizedDescription))
            }
            self.pump()
        }
    }
}
