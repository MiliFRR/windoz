// SPDX-License-Identifier: GPL-3.0-or-later
// Windoz Converter Exception: see LICENSE-EXCEPTION.md
//
// Ported from Madeira's JITSetup.swift and JITNetwork.swift (GPL-3.0-or-later,
// Madeira Converter Exception), adapted to Windoz: logging goes through
// EngineLogStream, the local-network shortcut is not ported (the loopback check
// and LocalDevVPN connect are), and the built-in helper is Windoz's own.

import Darwin
import Foundation
import Security
import UIKit

/// Where Built-in JIT's pairing file came from.
enum JITPairingSource: String {
    /// Made by Windoz on this device (iOS 27, OnDevicePairing).
    case onDevice
    /// Imported from a file made on a computer.
    case imported
}

/// This iPhone's remote pairing file for Built-in JIT. It is a credential
/// for the device itself, so it lives in the Keychain (this device only, while
/// unlocked), as the Steam sign-in token does, and never in Documents, where
/// the Files app and every Windows program in Windoz could read it. Its bytes
/// go only to the bundled helper, for one request. A copy an earlier build
/// left at Documents/StikJIT/pairingFile.plist moves into the Keychain and is
/// deleted.
enum JITPairingFileStore {
    private static let service = "WindozJITPairing"
    private static let account = "rppairing"
    private static let sourceKey = "windozJITPairingSource"

    static var isImported: Bool { (try? data()) != nil }

    /// Files stored before on-device pairing existed were all imported.
    static var source: JITPairingSource? {
        guard isImported else { return nil }
        return UserDefaults.standard.string(forKey: sourceKey).flatMap(JITPairingSource.init(rawValue:)) ?? .imported
    }

    static func data() throws -> Data {
        moveLegacyFile()
        var result: AnyObject?
        let status = SecItemCopyMatching([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ] as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data, !data.isEmpty else {
            throw NSError(domain: "WindozJIT", code: 11,
                          userInfo: [NSLocalizedDescriptionKey: "No pairing file is stored for this device."])
        }
        return data
    }

    static func importFile(from source: URL) throws {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        try store(try Data(contentsOf: source), source: .imported)
    }

    /// Validates an RPPairing plist and makes it the pairing file.
    static func store(_ data: Data, source: JITPairingSource) throws {
        guard !data.isEmpty,
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dictionary = plist as? [String: Any],
              let publicKey = dictionary["public_key"] as? Data, publicKey.count == 32,
              let privateKey = dictionary["private_key"] as? Data, privateKey.count == 32,
              let identifier = dictionary["identifier"] as? String, !identifier.isEmpty else {
            throw NSError(domain: "WindozJIT", code: 10,
                          userInfo: [NSLocalizedDescriptionKey:
                            "That is not a StikDebug remote pairing file. Create one with iloader and try again."])
        }
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(item as CFDictionary)
        var add = item
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: "WindozJIT", code: 12,
                          userInfo: [NSLocalizedDescriptionKey:
                            "The pairing file could not be saved in the Keychain (\(status)). Unlock this device and try again."])
        }
        UserDefaults.standard.set(source.rawValue, forKey: sourceKey)
    }

    /// Documents/StikJIT/pairingFile.plist, where builds before the Keychain kept it.
    private static var legacyFolder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("StikJIT", isDirectory: true)
    }

    private static func moveLegacyFile() {
        let manager = FileManager.default
        let file = legacyFolder.appendingPathComponent("pairingFile.plist")
        guard manager.fileExists(atPath: file.path), let data = try? Data(contentsOf: file) else { return }
        let kept = UserDefaults.standard.string(forKey: sourceKey).flatMap(JITPairingSource.init(rawValue:)) ?? .imported
        // Deleted only once the Keychain holds it (a locked device keeps it for later).
        if (try? store(data, source: kept)) != nil {
            try? manager.removeItem(at: file)
            if (try? manager.contentsOfDirectory(atPath: legacyFolder.path))?.isEmpty == true {
                try? manager.removeItem(at: legacyFolder)
            }
            EngineLogStream.shared.append("[jit] pairing file moved from Documents into the Keychain")
        }
    }
}

/// How this copy is signed, from the process's code-signing flags: whether a
/// debugger may attach (get-task-allow), which StikDebug and the bundled helper
/// both need. Ported from Madeira's EntitlementChecker (jit_cs_status, the
/// engine's own C check).
struct SigningStatus {
    let known: Bool
    let flags: UInt32
    /// CS_GET_TASK_ALLOW. Unknown flags count as debuggable, so a failed query
    /// never blocks a copy that works.
    var debuggable: Bool { !known || flags & 0x4 != 0 }
    var debugged: Bool { known && flags & 0x1000_0000 != 0 }

    static var current: SigningStatus {
        var flags: UInt32 = 0
        let known = jit_cs_status(&flags)
        return SigningStatus(known: known, flags: flags)
    }
    static let notDebuggableMessage = "JIT cannot be enabled on this copy of Windoz: it was signed without get-task-allow "
        + "(a distribution or enterprise certificate). Reinstall it with a development signing — AltStore, SideStore, Plume or LiveContainer's own — and try again."
}

/// StikDebug, the separate app that can attach a debugger to this process.
enum StikDebugApp {
    static var isInstalled: Bool {
        guard let url = URL(string: "stikdebug://") else { return false }
        return UIApplication.shared.canOpenURL(url)
    }
}

@MainActor
final class JITCoordinator: ObservableObject {
    static let shared = JITCoordinator()

    enum CoordinatorError: LocalizedError {
        case setupRequired(String)
        case pairingMissing
        case scriptMissing
        case timedOut

        var errorDescription: String? {
            switch self {
            case .setupRequired(let message): return message
            case .pairingMissing: return "Pair this device or import its pairing file first."
            case .scriptMissing: return "Windoz's JIT script is missing from this installation. Reinstall Windoz."
            case .timedOut: return "The debugger did not attach within 90 seconds. Check the pairing file and LocalDevVPN, then try again."
            }
        }
    }

    /// Why the built-in helper could not reach this device, read from its error.
    enum ConnectionProblem: Equatable {
        /// Nothing answered at LocalDevVPN's address: the VPN is off or not routing.
        case vpn
        /// The device closed the connection, usually because it no longer accepts this
        /// pairing (every new pairing replaces the last).
        case pairing

        init?(helperMessage: String) {
            let text = helperMessage.lowercased()
            let has = { (needles: [String]) in needles.contains(where: text.contains) }
            if has(["connectionreset", "connection reset", "device refused connection"]) {
                self = .pairing
            } else if has(["connectionrefused", "connection refused", "timedout", "timed out",
                           "networkunreachable", "network unreachable", "hostunreachable", "host unreachable", "no route"]) {
                self = .vpn
            } else {
                return nil
            }
        }

        var message: String {
            switch self {
            case .vpn:
                return "Windoz couldn't reach this device. Connect LocalDevVPN, then try again."
            case .pairing:
                return "This device closed the connection, which usually means it no longer accepts Windoz's pairing. Pair again, and check that LocalDevVPN is connected."
            }
        }
    }

    @Published var method: JITMethod {
        didSet { UserDefaults.standard.set(method.rawValue, forKey: "windozJITMethod") }
    }
    @Published private(set) var connectionProblem: ConnectionProblem?
    /// What the last loopback check found (nil: none ran). A JIT failure after it found no
    /// lockdownd is a LocalDevVPN problem whatever the helper's message says: a network
    /// that accepts any connection makes the helper's read end early ("early eof").
    private var loopbackAnswered: Bool?
    @Published var showSetup = false
    @Published private(set) var busy = false
    @Published private(set) var status: String?
    @Published private(set) var error: String?
    @Published private(set) var txmPresent: Bool?
    @Published private(set) var pairingImported = JITPairingFileStore.isImported
    @Published private(set) var pairingSource = JITPairingFileStore.source

    private init() {
        method = UserDefaults.standard.string(forKey: "windozJITMethod")
            .flatMap(JITMethod.init(rawValue:)) ?? .automatic
    }

    var resolvedMethod: JITMethod {
        guard method == .automatic else { return method }
        return StikDebugApp.isInstalled ? .stikDebug : .builtIn
    }

    var automaticDescription: String {
        StikDebugApp.isInstalled
            ? "StikDebug is installed, so Windoz will open it directly."
            : "StikDebug was not detected, so Windoz will use its built-in helper."
    }

    func refreshPairingStatus() {
        pairingImported = JITPairingFileStore.isImported
        pairingSource = JITPairingFileStore.source
    }

    func enable(completion: @escaping (Result<Void, Error>) -> Void) {
        guard SigningStatus.current.debuggable else {
            completion(.failure(NSError(
                domain: "WindozJIT", code: 11,
                userInfo: [NSLocalizedDescriptionKey: SigningStatus.notDebuggableMessage])))
            return
        }
        if JITManager.probeEnabled() {
            completion(.success(()))
            return
        }
        error = nil
        status = nil
        connectionProblem = nil
        ensureLoopback { [weak self] in
            self?.enableResolved(completion)
        }
    }

    /// LocalDevVPN's loopback first (milliseconds when it already works). The
    /// result only shapes the explanation: a JIT attempt follows either way, so
    /// a failure still gets the usual plain-language reason.
    private func ensureLoopback(then proceed: @escaping () -> Void) {
        let vpnWasUp = LoopbackProbe.vpnInterfaceUp
        LoopbackProbe.check { [weak self] probe in
            EngineLogStream.shared.append(String(format: "[jit-loopback] %@ in %.0f ms (vpn-interface=%d, %@)",
                                                 probe.reachable ? "reachable" : "unreachable", probe.milliseconds,
                                                 vpnWasUp ? 1 : 0, probe.detail))
            self?.loopbackAnswered = probe.reachable
            proceed()
        }
    }

    private func enableResolved(_ completion: @escaping (Result<Void, Error>) -> Void) {
        switch resolvedMethod {
        case .automatic:
            assertionFailure("Automatic must resolve to a concrete JIT method")
        case .stikDebug:
            guard StikDebugApp.isInstalled else {
                let message = "StikDebug is not installed. Install it, or choose Built-in StikJIT (available outside LiveContainer)."
                error = message
                showSetup = true
                completion(.failure(CoordinatorError.setupRequired(message)))
                return
            }
            guard let url = JITManager.stikDebugEnableURL() else {
                let message = CoordinatorError.scriptMissing.localizedDescription
                error = message
                completion(.failure(CoordinatorError.scriptMissing))
                return
            }
            busy = true
            status = "Waiting for StikDebug…"
            UIApplication.shared.open(url, options: [:]) { [weak self] opened in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    guard opened else {
                        self.busy = false
                        self.error = "StikDebug did not open. Is it installed?"
                        completion(.failure(CoordinatorError.setupRequired("StikDebug did not open.")))
                        return
                    }
                    self.waitForEnabled { [weak self] result in
                        guard let self else { return }
                        self.busy = false
                        self.status = (try? result.get()).map { _ in "StikDebug is attached." }
                        if case .failure(let failure) = result { self.error = failure.localizedDescription }
                        completion(result)
                    }
                }
            }
        case .builtIn:
            guard JITManager.builtInHelperUsable else {
                let message = WindozBuiltInJIT.unavailableReason ?? "Built-in JIT is unavailable."
                error = message
                showSetup = true
                completion(.failure(CoordinatorError.setupRequired(message)))
                return
            }
            guard JITPairingFileStore.isImported else {
                let message = "Pair this device or import its pairing file to finish Built-in JIT setup."
                error = message
                showSetup = true
                completion(.failure(CoordinatorError.setupRequired(message)))
                return
            }
            enableBuiltIn(completion: completion)
        }
    }

    /// A launch can ask for one silent attempt: only the built-in helper can
    /// attach without leaving Windoz or asking the user anything. StikDebug
    /// cannot (it opens another app), so its path stays a button in JIT setup.
    /// Returns whether JIT is ready afterwards.
    func autoEnableIfPossible() async -> Bool {
        if JITManager.probeEnabled() { return true }
        guard resolvedMethod == .builtIn, !busy,
              JITManager.builtInHelperUsable, JITPairingFileStore.isImported else { return false }
        return await withCheckedContinuation { continuation in
            enableBuiltIn { result in
                switch result {
                case .success: continuation.resume(returning: true)
                case .failure: continuation.resume(returning: JITManager.probeEnabled())
                }
            }
        }
    }

    /// windoz://…, from LocalDevVPN's `scheme=windoz` return or any other link.
    /// Re-checks the loopback so the setup screen shows the tunnel's real state.
    @discardableResult
    func handleOpenURL(_ url: URL) -> Bool {
        guard url.scheme == "windoz" else { return false }
        EngineLogStream.shared.append("[jit] returned through windoz://\(url.host ?? "")")
        LoopbackProbe.check { [weak self] probe in
            EngineLogStream.shared.append(String(format: "[jit-loopback] %@ in %.0f ms (%@)",
                                                 probe.reachable ? "reachable" : "unreachable",
                                                 probe.milliseconds, probe.detail))
            self?.loopbackAnswered = probe.reachable
        }
        return true
    }

    func importPairingFile(_ source: URL) {
        do {
            try JITPairingFileStore.importFile(from: source)
            OnDevicePairing.shared.cancel()
            refreshPairingStatus()
            status = "Pairing file imported."
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// OnDevicePairing finished: its file becomes the pairing file and Built-in JIT the method.
    func storeOnDevicePairing(_ data: Data) throws {
        try JITPairingFileStore.store(data, source: .onDevice)
        refreshPairingStatus()
        method = .builtIn
        status = "Paired in Windoz."
        error = nil
    }

    func prepareBuiltIn() {
        guard SigningStatus.current.debuggable else {
            error = SigningStatus.notDebuggableMessage
            return
        }
        guard WindozBuiltInJIT.isAvailable else {
            error = WindozBuiltInJIT.unavailableReason
            return
        }
        guard let pairing = try? JITPairingFileStore.data() else {
            error = CoordinatorError.pairingMissing.localizedDescription
            return
        }
        busy = true
        error = nil
        connectionProblem = nil
        status = "Checking LocalDevVPN and the Developer Disk Image…"
        WindozBuiltInJIT.send(.prepare(pairingData: pairing)) { [weak self] result in
            guard let self else { return }
            busy = false
            switch result {
            case .success(let response):
                txmPresent = response.txmPresent
                status = response.success ? response.message : nil
                error = response.success ? nil : helperFailure(response.message)
            case .failure(let failure):
                error = failure.localizedDescription
            }
        }
    }

    func enableBuiltIn(completion: @escaping (Result<Void, Error>) -> Void = { _ in }) {
        guard WindozBuiltInJIT.isAvailable else {
            let failure = NSError(
                domain: "WindozJIT", code: 12,
                userInfo: [NSLocalizedDescriptionKey:
                    WindozBuiltInJIT.unavailableReason ?? "Built-in JIT is unavailable."])
            error = failure.localizedDescription
            completion(.failure(failure))
            return
        }
        guard let pairing = try? JITPairingFileStore.data() else {
            error = CoordinatorError.pairingMissing.localizedDescription
            completion(.failure(CoordinatorError.pairingMissing))
            return
        }
        guard let script = JITManager.jitScriptBase64() else {
            error = CoordinatorError.scriptMissing.localizedDescription
            completion(.failure(CoordinatorError.scriptMissing))
            return
        }

        busy = true
        error = nil
        status = "Starting Windoz's JIT helper…"
        var readinessTimer: Timer?
        var readinessFinished = false
        WindozBuiltInJIT.send(
            .enable(targetPID: getpid(), pairingData: pairing, scriptBase64: script),
            started: { [weak self] in
                self?.status = "Waiting for Windoz's JIT helper to attach…"
                readinessTimer = self?.waitForEnabled { [weak self] result in
                    guard !readinessFinished else { return }
                    readinessFinished = true
                    self?.busy = false
                    switch result {
                    case .success:
                        self?.status = "Built-in JIT is attached."
                        self?.error = nil
                    case .failure(let failure):
                        self?.error = failure.localizedDescription
                    }
                    completion(result)
                }
            },
            completion: { [weak self] result in
                switch result {
                case .success(let response):
                    self?.txmPresent = response.txmPresent
                    EngineLogStream.shared.append("[jit-built-in] \(response.message)",
                                                  level: response.success ? .success : .error)
                    if !response.success && !readinessFinished, let self {
                        readinessFinished = true
                        readinessTimer?.invalidate()
                        busy = false
                        let message = helperFailure(response.message)
                        error = message
                        completion(.failure(NSError(
                            domain: "WindozJIT", code: 13,
                            userInfo: [NSLocalizedDescriptionKey: message])))
                    }
                case .failure(let failure):
                    if !readinessFinished {
                        readinessFinished = true
                        readinessTimer?.invalidate()
                        self?.busy = false
                        self?.error = failure.localizedDescription
                        completion(.failure(failure))
                    }
                }
            })
    }

    /// The helper's failure as shown: a connection problem gets its plain explanation
    /// (the helper's own message is already in the log).
    private func helperFailure(_ message: String) -> String {
        connectionProblem = ConnectionProblem(helperMessage: message) ?? (loopbackAnswered == false ? .vpn : nil)
        return connectionProblem?.message ?? message
    }

    func resetDDI() {
        busy = true
        error = nil
        status = "Resetting the Developer Disk Image cache…"
        WindozBuiltInJIT.send(.resetDDI) { [weak self] result in
            self?.busy = false
            switch result {
            case .success(let response):
                self?.status = response.success ? response.message : nil
                self?.error = response.success ? nil : response.message
            case .failure(let failure):
                self?.error = failure.localizedDescription
            }
        }
    }

    /// Waits until JIT can actually serve a launch: the engine rule (CS_DEBUGGED
    /// plus a debugger attached right now, JITManager.probeEnabled). Opening a
    /// URL, or a helper request completing, only proves the tool ran. Main thread.
    @discardableResult
    func waitForEnabled(timeout: TimeInterval = 90,
                        completion: @escaping (Result<Void, Error>) -> Void) -> Timer {
        let deadline = Date().addingTimeInterval(timeout)
        let timer = Timer(timeInterval: 0.5, repeats: true) { timer in
            MainActor.assumeIsolated {
                if JITManager.probeEnabled() {
                    timer.invalidate()
                    EngineLogStream.shared.append("[jit] JIT enabled and debugger attached.", level: .success)
                    completion(.success(()))
                } else if Date() >= deadline {
                    timer.invalidate()
                    EngineLogStream.shared.append("[jit] no debugger within \(Int(timeout)) s.", level: .error)
                    completion(.failure(CoordinatorError.timedOut))
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }
}

/// LocalDevVPN, which built-in JIT and StikDebug reach the device through: open it to
/// connect when it is installed, otherwise its App Store page.
enum LocalDevVPN {
    static let appStore = URL(string: "https://apps.apple.com/us/app/localdevvpn/id6755608044")!
    /// `enable` connects the VPN; `scheme` has LocalDevVPN return to Windoz a second later.
    static let connect = URL(string: "localdevvpn://enable?scheme=windoz")!

    static var isInstalled: Bool { UIApplication.shared.canOpenURL(URL(string: "localdevvpn://")!) }
    static var actionTitle: String { isInstalled ? "Connect LocalDevVPN" : "Get LocalDevVPN" }

    static func open() {
        let installed = isInstalled
        EngineLogStream.shared.append("[jit] LocalDevVPN \(installed ? "connect" : "app-store")")
        UIApplication.shared.open(installed ? connect : appStore)
    }
}

/// Whether LocalDevVPN's loopback reaches this device's lockdownd at 10.7.0.1:62078
/// (the address StikDebug uses). Two steps, neither depending on what lockdownd says
/// (over USB it answers a plain QueryType; through the tunnel it closed the connection):
/// 1. The route: the interface traffic to 10.7.0.1 would leave by, asked of the kernel
///    with an unsent UDP connect (no packets, microseconds). Not a VPN interface means
///    LocalDevVPN is not routing it, so a network that accepts any connection (a proxy)
///    is never asked. It must also be LocalDevVPN's interface, whose address is in
///    10.7.0.0/16: another VPN carrying all traffic also routes 10.7.0.1 and accepts
///    the connection, but the JIT helper then reads "early eof".
/// 2. Through LocalDevVPN: a TCP connection, at most `timeout`. Through a working
///    tunnel it opens in milliseconds; over cellular data, where the tunnel does not
///    work, it fails. Nothing is sent, and it is closed at once.
/// Ported unchanged from Madeira's JITNetwork.swift (GPL-3.0-or-later, Madeira
/// Converter Exception).
enum LoopbackProbe {
    static let address = "10.7.0.1"
    static let port: UInt16 = 62078

    struct Result {
        let reachable: Bool
        let milliseconds: Double
        let detail: String
    }

    struct Route {
        let interface: String
        let address: String
        /// utun (packet tunnels such as LocalDevVPN), ipsec or ppp.
        var isVPN: Bool { ["utun", "ipsec", "ppp"].contains { interface.hasPrefix($0) } }
        /// LocalDevVPN's own tunnel: a VPN interface whose address is in its 10.7.0.0/16.
        var isLocalDevVPN: Bool { isVPN && address.hasPrefix("10.7.") }
    }

    private static func target() -> sockaddr_in? {
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        return inet_pton(AF_INET, address, &addr.sin_addr) == 1 ? addr : nil
    }

    private static func connect(_ fd: Int32, _ addr: inout sockaddr_in) -> Int32 {
        withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
    }

    /// The interface and local address traffic to 10.7.0.1 would leave by; nil without a route.
    static func route() -> Route? {
        guard var addr = target() else { return nil }
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        guard connect(fd, &addr) == 0 else { return nil }
        var local = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let got = withUnsafeMutablePointer(to: &local) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        guard got == 0 else { return nil }
        var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        var sin = local.sin_addr
        inet_ntop(AF_INET, &sin, &text, socklen_t(INET_ADDRSTRLEN))
        return Route(interface: interfaceName(holding: local.sin_addr.s_addr) ?? "?", address: String(cString: text))
    }

    private static func interfaceName(holding ip: in_addr_t) -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            if let sa = entry.pointee.ifa_addr, sa.pointee.sa_family == sa_family_t(AF_INET),
               sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1, { $0.pointee.sin_addr.s_addr }) == ip {
                return String(cString: entry.pointee.ifa_name)
            }
            cursor = entry.pointee.ifa_next
        }
        return nil
    }

    /// Blocks for at most `timeout`; use `check(timeout:completion:)` from the main thread.
    /// `requireVPN` is false only for host tests, whose listeners are on lo0.
    static func check(timeout: TimeInterval = 0.4, requireVPN: Bool = true) -> Result {
        let start = CFAbsoluteTimeGetCurrent()
        func done(_ ok: Bool, _ detail: String) -> Result {
            Result(reachable: ok, milliseconds: (CFAbsoluteTimeGetCurrent() - start) * 1000, detail: detail)
        }
        guard let route = route() else { return done(false, "no route") }
        if requireVPN, !route.isVPN { return done(false, "routed via \(route.interface), not a VPN") }
        if requireVPN, !route.isLocalDevVPN {
            return done(false, "routed via \(route.interface) \(route.address): another VPN, not LocalDevVPN")
        }
        guard var addr = target() else { return done(false, "bad address") }
        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { return done(false, "socket: \(String(cString: strerror(errno)))") }
        defer { close(fd) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK)
        if connect(fd, &addr) != 0 {
            guard errno == EINPROGRESS else { return done(false, String(cString: strerror(errno))) }
            var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            let ready = poll(&pfd, 1, Int32(max(1, (start + timeout - CFAbsoluteTimeGetCurrent()) * 1000)))
            guard ready > 0 else { return done(false, ready == 0 ? "timed out via \(route.interface)" : String(cString: strerror(errno))) }
            var err: Int32 = 0
            var len = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len)
            guard err == 0 else { return done(false, "\(String(cString: strerror(err))) via \(route.interface)") }
        }
        return done(true, "connected via \(route.interface) \(route.address)")
    }

    static func check(timeout: TimeInterval = 0.4, completion: @escaping @MainActor (Result) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = check(timeout: timeout)
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(result) } }
        }
    }

    /// Checks again until the loopback answers or `within` seconds pass: a VPN that
    /// was just connected needs a moment before it routes.
    static func waitUntilReachable(within: TimeInterval, completion: @escaping @MainActor (Result) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let deadline = CFAbsoluteTimeGetCurrent() + within
            var result = check(timeout: 0.4)
            while !result.reachable, CFAbsoluteTimeGetCurrent() < deadline {
                Thread.sleep(forTimeInterval: 0.25)
                result = check(timeout: 0.4)
            }
            let final = result
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(final) } }
        }
    }

    /// LocalDevVPN is connected: traffic to 10.7.0.1 leaves by its tunnel. Instant: no
    /// network traffic.
    static var vpnInterfaceUp: Bool { route()?.isLocalDevVPN ?? false }
}
