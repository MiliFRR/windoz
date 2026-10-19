// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 125hz
//
// The in-session performance overlay: FPS with 1 % and 0.1 % lows, the app's
// RAM footprint, process CPU and battery. Every number is measured on the
// device — nothing here estimates. The CPU meter is ported from Madeira's
// `CPUMeter` (GPL-3.0-or-later with the Madeira Converter Exception).

import Foundation
import UIKit
import QuartzCore
import Darwin

/// The overlay card. Sampling runs on the main run loop at 4 Hz: the frame
/// counter is the engine's own presented-frame export, and the FPS lows are
/// percentiles of the sampled frame times over the last minute.
final class SessionPerformanceView: UIView {

    /// One toggle for the whole overlay, shared by every game.
    static let visibilityKey = "windoz.hud.performance"

    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: visibilityKey) }
        set { UserDefaults.standard.set(newValue, forKey: visibilityKey) }
    }

    private let fpsValue = SessionPerformanceView.valueLabel()
    private let low1Value = SessionPerformanceView.valueLabel()
    private let low01Value = SessionPerformanceView.valueLabel()
    private let ramValue = SessionPerformanceView.valueLabel()
    private let cpuValue = SessionPerformanceView.valueLabel()
    private let batteryValue = SessionPerformanceView.valueLabel()

    private var timer: Timer?
    private let cpuMeter = SessionCPUMeter()
    private var frameTimes: [Double] = []      // seconds per frame, newest last
    private var lastFrames: UInt64 = 0
    private var lastWall = 0.0
    private var displayedFPS = 0.0
    private var sessionStartBattery: Float = -1

    var isShown: Bool = false {
        didSet {
            isHidden = !isShown
            if isShown { start() } else { stop() }
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor.black.withAlphaComponent(0.62)
        layer.cornerRadius = 12
        layer.borderWidth = 1
        layer.borderColor = UIColor.white.withAlphaComponent(0.14).cgColor
        isUserInteractionEnabled = false
        isHidden = true
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private static func valueLabel() -> UILabel {
        let label = UILabel()
        label.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        label.textColor = .white
        label.text = "—"
        return label
    }

    private static func captionLabel(_ text: String) -> UILabel {
        let label = UILabel()
        label.font = .systemFont(ofSize: 10, weight: .medium)
        label.textColor = UIColor.white.withAlphaComponent(0.55)
        label.text = text
        return label
    }

    private func build() {
        func row(_ caption: String, _ value: UILabel) -> UIStackView {
            let captionLabel = Self.captionLabel(caption)
            captionLabel.widthAnchor.constraint(equalToConstant: 34).isActive = true
            let stack = UIStackView(arrangedSubviews: [captionLabel, value])
            stack.axis = .horizontal
            stack.spacing = 6
            stack.alignment = .firstBaseline
            return stack
        }

        let left = UIStackView(arrangedSubviews: [
            row("FPS", fpsValue), row("1%", low1Value), row("0.1%", low01Value),
        ])
        left.axis = .vertical
        left.spacing = 4
        let right = UIStackView(arrangedSubviews: [
            row("RAM", ramValue), row("CPU", cpuValue), row("BAT", batteryValue),
        ])
        right.axis = .vertical
        right.spacing = 4

        let columns = UIStackView(arrangedSubviews: [left, right])
        columns.axis = .horizontal
        columns.spacing = 18
        columns.translatesAutoresizingMaskIntoConstraints = false
        addSubview(columns)
        NSLayoutConstraint.activate([
            columns.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            columns.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            columns.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            columns.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])
    }

    // MARK: - Sampling

    func start() {
        guard timer == nil else { return }
        UIDevice.current.isBatteryMonitoringEnabled = true
        sessionStartBattery = UIDevice.current.batteryLevel
        lastFrames = madeira_get_present_count()
        lastWall = CACurrentMediaTime()
        frameTimes.removeAll()
        displayedFPS = 0
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.sample() }
        timer.tolerance = 0.05
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        sample()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func sample() {
        let now = CACurrentMediaTime()
        let frames = madeira_get_present_count()
        let elapsed = now - lastWall
        lastWall = now
        let delta = frames >= lastFrames ? frames - lastFrames : 0
        lastFrames = frames
        guard elapsed > 0 else { return }

        let fps = Double(delta) / elapsed
        displayedFPS = displayedFPS == 0 ? fps : displayedFPS * 0.65 + fps * 0.35
        if delta > 0 {
            let frameTime = elapsed / Double(delta)
            frameTimes.append(frameTime)
            if frameTimes.count > 240 { frameTimes.removeFirst(frameTimes.count - 240) }
        }

        fpsValue.text = String(format: "%.0f", displayedFPS)
        low1Value.text = Self.percentileFPS(frameTimes, 0.99)
        low01Value.text = Self.percentileFPS(frameTimes, 0.999)

        let footprint = JITManager.physicalFootprintBytes()
        ramValue.text = footprint > 0
            ? ByteCountFormatter.string(fromByteCount: footprint, countStyle: .memory)
            : "—"

        if let cpu = cpuMeter.sample() {
            cpuValue.text = String(format: "%.0f%%", cpu)
        } else {
            cpuValue.text = "—"
        }
        batteryValue.text = batteryText()
    }

    /// The FPS at the given frame-time percentile: "1 % low" is the 99th
    /// percentile frame time, "0.1 % low" the 99.9th. The sample window is the
    /// last minute at 4 Hz. Nil until there is enough signal to mean anything.
    private static func percentileFPS(_ samples: [Double], _ percentile: Double) -> String {
        guard samples.count >= 20 else { return "—" }
        let sorted = samples.sorted()
        let index = min(sorted.count - 1, Int((Double(sorted.count - 1) * percentile).rounded()))
        let frameTime = sorted[index]
        return frameTime > 0 ? String(format: "%.0f", 1.0 / frameTime) : "—"
    }

    private func batteryText() -> String {
        let device = UIDevice.current
        let level = device.batteryLevel
        guard level >= 0 else { return "—" }
        var text = String(format: "%.0f%%", level * 100)
        switch device.batteryState {
        case .charging, .full:
            text += " ⚡"
        default:
            if sessionStartBattery >= 0 {
                let delta = Int(((level - sessionStartBattery) * 100).rounded())
                if delta != 0 { text += String(format: " %+d%%", delta) }
            }
        }
        return text
    }
}

/// Process CPU time as a share of all cores, from each thread's own CPU time.
/// `nil` on the first sample and when the thread list cannot be read.
final class SessionCPUMeter {
    private var last: [UInt64: Double] = [:]
    private var lastWall = 0.0
    private let cores = Double(max(1, ProcessInfo.processInfo.activeProcessorCount))

    func sample() -> Double? {
        var list: thread_act_array_t?
        var count: mach_msg_type_number_t = 0
        guard task_threads(mach_task_self_, &list, &count) == KERN_SUCCESS, let list else { return nil }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: list)),
                          vm_size_t(Int(count) * MemoryLayout<thread_t>.stride))
        }
        let wall = CACurrentMediaTime()
        var now: [UInt64: Double] = [:]
        var sum = 0.0
        for index in 0..<Int(count) {
            let thread = list[index]
            defer { mach_port_deallocate(mach_task_self_, thread) }
            var ident = thread_identifier_info_data_t()
            var identCount = mach_msg_type_number_t(
                MemoryLayout<thread_identifier_info_data_t>.size / MemoryLayout<natural_t>.size)
            var basic = thread_basic_info_data_t()
            var basicCount = mach_msg_type_number_t(
                MemoryLayout<thread_basic_info_data_t>.size / MemoryLayout<natural_t>.size)
            let identResult = withUnsafeMutablePointer(to: &ident) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(identCount)) {
                    thread_info(thread, thread_flavor_t(THREAD_IDENTIFIER_INFO), $0, &identCount)
                }
            }
            let basicResult = withUnsafeMutablePointer(to: &basic) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(basicCount)) {
                    thread_info(thread, thread_flavor_t(THREAD_BASIC_INFO), $0, &basicCount)
                }
            }
            guard identResult == KERN_SUCCESS, basicResult == KERN_SUCCESS else { continue }
            let seconds = Double(basic.user_time.seconds + basic.system_time.seconds)
                + Double(basic.user_time.microseconds + basic.system_time.microseconds) / 1e6
            now[ident.thread_id] = seconds
            if let before = last[ident.thread_id] {
                sum += max(0, seconds - before)
            }
        }
        let interval = wall - lastWall
        let first = last.isEmpty
        last = now
        lastWall = wall
        guard !first, interval > 0 else { return nil }
        return min(100, sum / interval / cores * 100)
    }
}
