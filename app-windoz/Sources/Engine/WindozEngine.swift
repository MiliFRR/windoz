import Foundation

/// The engine boundary. Everything above this file talks only to WindozEngine;
/// nothing above it imports Wine, FEX or DXMT symbols directly.
///
/// Reuse statement: the underlying C/ObjC binding layer (WineProcessBridge,
/// FEXBridge, WineServerBridge, JITAllocator, PrefixExtractor — GPL-3.0,
/// © the Madeira/FEX authors) drives the pinned engine forks and is treated
/// as part of the engine, per the project's ground rules. Everything above
/// this boundary is original Windoz code.

enum EngineHealth: Equatable {
    case unknown
    case checking
    case ready
    case unavailable(String)
}

struct EngineStatus: Equatable {
    var jit: EngineHealth = .unknown
    var memoryEntitlement: EngineHealth = .unknown
    var freeStorageBytes: Int64 = 0
}

/// A game the user added from the Files app. (Store providers land in a
/// later phase behind the StoreProvider protocol.)
struct LocalGame: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var title: String
    var exePath: String          // absolute path inside the app sandbox
    var addedAt: Date = Date()

    static let storeKey = "windoz.localGames.v1"
}

final class WindozEngine: ObservableObject {
    static let shared = WindozEngine()

    @Published var status = EngineStatus()

    private let queue = DispatchQueue(label: "windoz.engine", qos: .userInitiated)

    // MARK: - Health

    /// Runs the JIT probe and the memory-entitlement check off the main thread.
    func refreshStatus() {
        status.jit = .checking
        status.memoryEntitlement = .checking
        queue.async { [weak self] in
            guard let self else { return }
            let jitOK = windoz_jit_probe() != 0
            let mem = Self.memoryLimitBytes()
            DispatchQueue.main.async {
                self.status.jit = jitOK ? .ready : .unavailable(
                    "JIT is only available while a debugger is attached. Install StikDebug, attach it to Windoz, then try again.")
                self.status.memoryEntitlement = mem == nil
                    ? .unavailable("The increased-memory entitlement is not active in this signing.")
                    : .ready
                self.status.freeStorageBytes = Self.freeStorageBytes()
            }
        }
    }

    /// Increased-memory entitlement check: task_vm_info reports how many
    /// bytes of physical footprint the task may still use. Without the
    /// entitlement the limit is small and fixed; with it, far larger.
    static func memoryLimitBytes() -> Int64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { infoPtr in
            infoPtr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        // limit_bytes_remaining is only meaningful when the kernel applied a
        // raised limit; zero means "no limit reported".
        let remaining = Int64(info.limit_bytes_remaining)
        return remaining > 0 ? remaining : nil
    }

    static func freeStorageBytes() -> Int64 {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        guard let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let bytes = values.volumeAvailableCapacityForImportantUsage else { return 0 }
        return bytes
    }

    // MARK: - Prefix + wineserver

    /// The Wine prefix lives in the app's Documents directory.
    var prefixURL: URL {
        URL.documentsDirectory.appendingPathComponent("windos-prefix", isDirectory: true)
    }

    /// Seeds the prefix (first run) and reports whether the wineserver starts
    /// and reaches its ready state. This exercises the real engine chain
    /// (wineserver thread + wine process init) without claiming a full
    /// game-session host, which is still being ported behind this API.
    func startEngineCore() async throws {
        let prefix = prefixURL.path
        try FileManager.default.createDirectory(atPath: prefix, withIntermediateDirectories: true)
        madeira_seed_prefix_if_needed(prefix)

        let ready = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Bool, Error>) in
            queue.async {
                let rc = wineserver_start(prefix)
                guard rc == 0 else {
                    cont.resume(throwing: EngineError.wineserverStartFailed)
                    return
                }
                // The server flips to ready once its registry is loaded.
                for _ in 0..<120 {   // up to ~60 s
                    if wineserver_is_ready() == 1 { cont.resume(returning: true); return }
                    if wineserver_is_running() == 0 { continue }
                    Thread.sleep(forTimeInterval: 0.5)
                }
                cont.resume(returning: wineserver_is_ready() == 1)
            }
        }
        guard ready else { throw EngineError.wineserverNotReady }
        guard fex_initialize() else { throw EngineError.fexInitFailed }
    }

    func stopEngineCore() {
        queue.async {
            fex_shutdown()
            wineserver_stop()
        }
    }
}

enum EngineError: LocalizedError {
    case wineserverStartFailed
    case wineserverNotReady
    case fexInitFailed
    case sessionHostingNotPorted

    var errorDescription: String? {
        switch self {
        case .wineserverStartFailed: return "The wineserver could not start."
        case .wineserverNotReady: return "The wineserver started but did not reach its ready state."
        case .fexInitFailed: return "The CPU emulator (FEX) failed to initialize."
        case .sessionHostingNotPorted: return
            "The engine core works, but hosting a full game session (rendering + input) is still being ported into Windoz. This build starts the engine core only."
        }
    }
}

// MARK: - Local game library

final class LocalGameStore: ObservableObject {
    @Published var games: [LocalGame] = []

    init() {
        if let data = UserDefaults.standard.data(forKey: LocalGame.storeKey),
           let decoded = try? JSONDecoder().decode([LocalGame].self, from: data) {
            games = decoded
        }
    }

    func add(title: String, exePath: String) {
        games.append(LocalGame(title: title, exePath: exePath))
        persist()
    }

    func remove(_ game: LocalGame) {
        games.removeAll { $0.id == game.id }
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(games) {
            UserDefaults.standard.set(data, forKey: LocalGame.storeKey)
        }
    }
}
