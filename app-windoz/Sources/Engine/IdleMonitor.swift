// SPDX-License-Identifier: GPL-3.0-or-later
// Windoz Converter Exception: see LICENSE-EXCEPTION.md

#if DEBUG
import Foundation
import Darwin

/// Debug-only idle monitor (Phase 1). Every 30 s it samples this process's CPU
/// time, live thread count and thermal state into the engine log, so the
/// "near 0% CPU on an idle library screen" target can be read off the device
/// instead of guessed at. It is compiled out of Release builds entirely.
///
/// Read it from Settings → Diagnostics → Log (or the log export): lines say
/// `[idle] cpu=0.3% threads=11 thermal=nominal`.
final class IdleMonitor {
    static let shared = IdleMonitor()

    private var source: DispatchSourceTimer?
    private var lastCPUSeconds: Double?
    private var lastSampleAt: Date?

    private init() {}

    func start() {
        guard source == nil else { return }
        let timer = DispatchSource.makeTimerSource(
            queue: DispatchQueue(label: "windoz.idle-monitor", qos: .utility))
        timer.schedule(deadline: .now() + 30, repeating: 30, leeway: .seconds(5))
        timer.setEventHandler { [weak self] in self?.sample() }
        timer.resume()
        source = timer
    }

    func stop() {
        source?.cancel()
        source = nil
    }

    private func sample() {
        let now = Date()
        let cpu = Self.processCPUSeconds()
        var usage = "first sample"
        if let last = lastCPUSeconds, let lastAt = lastSampleAt {
            let elapsed = now.timeIntervalSince(lastAt)
            if elapsed > 0 {
                usage = String(format: "%.1f%%", max(cpu - last, 0) / elapsed * 100)
            }
        }
        lastCPUSeconds = cpu
        lastSampleAt = now
        let thermal = Self.thermalText(ProcessInfo.processInfo.thermalState)
        EngineLogStream.shared.append("[idle] cpu=\(usage) threads=\(Self.threadCount()) thermal=\(thermal)")
    }

    /// Total CPU seconds burned by this process, all threads, user + system.
    private static func processCPUSeconds() -> Double {
        var info = task_thread_times_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_thread_times_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_THREAD_TIMES_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        let user = Double(info.user_time.seconds) + Double(info.user_time.microseconds) / 1_000_000
        let system = Double(info.system_time.seconds) + Double(info.system_time.microseconds) / 1_000_000
        return user + system
    }

    /// Live threads in this process.
    private static func threadCount() -> Int {
        var list: thread_act_array_t?
        var count: mach_msg_type_number_t = 0
        guard task_threads(mach_task_self_, &list, &count) == KERN_SUCCESS, let list else { return 0 }
        vm_deallocate(mach_task_self_,
                      vm_address_t(UInt(bitPattern: list)),
                      vm_size_t(Int(count) * MemoryLayout<thread_t>.stride))
        return Int(count)
    }

    private static func thermalText(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }
}
#endif
