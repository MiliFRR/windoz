// SPDX-License-Identifier: GPL-3.0-or-later
// Windoz Converter Exception: see LICENSE-EXCEPTION.md
//
// Ported from Madeira's StikJITHelper.allocatePool() (willfaust/Madeira,
// GPL-3.0-or-later with the Madeira Converter Exception). This is the piece
// 0.6.0 was missing: the engine's Wine fork executes translated code only from
// the pool named by WINE_IOS_JIT_RX / WINE_IOS_JIT_RW / WINE_IOS_JIT_SIZE, and
// only the attached debugger can grant that memory on iOS 26. Madeira asks the
// debugger for the RX pages (jit26_prepare_region), mirrors them read/write,
// then detaches and starts Wine. Windoz used to call its own in-process
// FEXCore init instead and never published these variables, so the guest's
// executable mappings had nowhere to live — the launch screen froze.
//
// The placement rules below are Madeira's, kept because they are the measured
// device behaviour, not guesses:
//   • the pool must sit at or above 0x119000000 (FEX dispatcher encoding);
//   • it must not land in the guest 64 GB window [0x7000000000, 0x8000000000)
//     (fault handlers would classify pool PCs as guest addresses);
//   • it must not swallow the 0x140000000 executable window (a non-relocatable
//     main image must be able to load at its preferred base);
//   • the RW alias is data-only and can be placed anywhere the kernel agrees.
import Foundation
import Darwin

enum JITPool {
    private(set) static var pool: (rx: UnsafeMutableRawPointer, rw: UnsafeMutableRawPointer, size: Int)?
    /// Why the last `ensure()` returned false, in words for the session screen.
    private(set) static var failure: String?

    private static let goodLow: UInt64 = 0x119000000
    private static let guestLo: UInt64 = 0x7000000000
    private static let guestHi: UInt64 = 0x8000000000
    private static let exeWinBase: UInt64 = 0x140000000
    private static let exeWinSize: UInt64 = 0x8000000          // 128 MB
    /// The constructor's placeholder can be released once. A failed request
    /// followed by a retry must not unmap whatever took its place.
    private static var earlyPoolReleased = false

    /// This app run's pool exists. After the early detach the debugger is gone
    /// by design, so this — not CS_DEBUGGED alone — is what says JIT can serve
    /// a launch.
    static var isReady: Bool { pool != nil }

    static var sizeMB: Int { (pool?.size ?? 0) / (1024 * 1024) }

    /// Allocate (once per process) and publish the pool Wine executes from.
    /// Must run before `wineserver_start`: Wine's ntdll reads the variables as
    /// it brings the guest up. Call on the session queue; the debugger exchange
    /// can suspend the process for a moment.
    static func ensure(poolSizeMB requested: Int = 896) -> Bool {
        if let pool {
            log("[jit-pool] already ready: \(pool.size >> 20) MB at RX=\(hex(pool.rx)) — reusing it.")
            return true
        }
        failure = nil

        guard jit_check_debugged() else {
            failure = "JIT is not enabled for this copy of Windoz, so the CPU translator has no executable memory."
            log("[jit-pool] refused: CS_DEBUGGED is not set.", level: .error)
            return false
        }

        let debuggerAttached = windoz_jit_debugger_attached() != 0
        // A pool request is a BRK only a debugger can answer. With the handler
        // armed an unanswered request returns instead of killing the process;
        // an attached debugger still receives the BRK first (JITAllocator.c).
        jit_arm_trap_fallback()
        if !debuggerAttached {
            log("[jit-pool] no debugger is attached; an unanswered request will fail the launch instead of crashing.", level: .warning)
        }

        // FEX's dispatcher emit has a position-dependent bug below
        // 0x119000000 (the literal-pool fixups silently break and execution
        // branches to zero memory before the first compiled block). Madeira
        // pushes the allocator's first-fit frontier past that floor by
        // reserving 16 MB chunks with VM_FLAGS_ANYWHERE and keeping them for
        // the process lifetime. A fixed count loses the ASLR lottery, so pin
        // until the frontier crosses the floor (cap 512 MB of reservation;
        // PROT_NONE/zero-fill chunks cost no resident memory).
        let pinTarget: vm_address_t = 0x119000000
        let pinChunkSize = 16 << 20
        var pinChunks: [vm_address_t] = []
        for index in 0..<32 {
            var pinAddr: vm_address_t = 0
            let kr = vm_allocate(mach_task_self_, &pinAddr, vm_size_t(pinChunkSize), VM_FLAGS_ANYWHERE)
            guard kr == KERN_SUCCESS else {
                log("[jit-pool] low-address pin chunk \(index) failed (kr=\(kr)).", level: .warning)
                break
            }
            if pinAddr >= pinTarget {
                vm_deallocate(mach_task_self_, pinAddr, vm_size_t(pinChunkSize))
                log("[jit-pool] allocator frontier already at 0x\(String(UInt64(pinAddr), radix: 16)); no pin needed.")
                break
            }
            pinChunks.append(pinAddr)
            if pinAddr + vm_address_t(pinChunkSize) >= pinTarget { break }
        }
        if !pinChunks.isEmpty {
            log("[jit-pool] pinned \(pinChunks.count * 16) MB below 0x119000000 so first-fit stays in the FEX-safe range.")
        }

        // Hold the 0x140000000 window before asking for RX. JITAllocator.c's
        // constructor normally claimed it before main(); this covers a run
        // where something got there first.
        var windowHeld = false
        if madeira_early_window_base == UInt(exeWinBase) && madeira_early_window_size == UInt(exeWinSize) {
            windowHeld = true
            setenv("WINE_IOS_EXE_WINDOW", "140000000:8000000", 1)
            log("[jit-pool] executable window 0x140000000+128 MB was held at image load.")
        } else {
            var winAddr = vm_address_t(exeWinBase)
            let kr = vm_allocate(mach_task_self_, &winAddr, vm_size_t(exeWinSize), 0 /* fixed */)
            if kr == KERN_SUCCESS && winAddr == vm_address_t(exeWinBase) {
                _ = vm_protect(mach_task_self_, winAddr, vm_size_t(exeWinSize), 0, VM_PROT_NONE)
                windowHeld = true
                setenv("WINE_IOS_EXE_WINDOW", "140000000:8000000", 1)
                log("[jit-pool] reserved the 0x140000000 executable window (128 MB).")
            } else {
                if kr == KERN_SUCCESS { vm_deallocate(mach_task_self_, winAddr, vm_size_t(exeWinSize)) }
                log("[jit-pool] could not reserve 0x140000000 (kr=\(kr)); a non-relocatable image may be displaced.", level: .warning)
            }
        }

        // Release the constructor's placeholder directly above the window so
        // the debugger's first-fit request can use it. It is a PROT_NONE
        // reservation and costs no memory.
        let earlyPoolBase = vm_address_t(madeira_early_pool_base)
        if earlyPoolBase != 0 && earlyPoolReleased {
            log("[jit-pool] the early placeholder was already released by an earlier attempt; not unmapping it again.")
        } else if earlyPoolBase != 0 {
            vm_deallocate(mach_task_self_, earlyPoolBase, vm_size_t(madeira_early_pool_size))
            earlyPoolReleased = true
            log("[jit-pool] released the early placeholder at 0x\(String(UInt64(earlyPoolBase), radix: 16)) (\(madeira_early_pool_size >> 20) MB).")
        } else {
            log("[jit-pool] no early placeholder was obtained; placement is left to the kernel.", level: .warning)
        }

        var poolSize = max(requested, 256) << 20

        // Census the free holes in the low gap. Where the largest hole cannot
        // hold the requested pool, take the largest 16 MB-aligned fit of at
        // least 256 MB (Madeira: below ~500 MB expect heavy-game hitches).
        var holes: [(base: UInt64, size: UInt64)] = []
        var addr = vm_address_t(goodLow)
        var prevEnd = UInt64(goodLow)
        while UInt64(addr) < guestLo {
            var rsize: vm_size_t = 0
            var info = vm_region_basic_info_data_64_t()
            var count = mach_msg_type_number_t(MemoryLayout<vm_region_basic_info_data_64_t>.size / MemoryLayout<Int32>.size)
            var object: mach_port_t = 0
            let kr = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: Int32.self, capacity: Int(count)) {
                    vm_region_64(mach_task_self_, &addr, &rsize,
                                 VM_REGION_BASIC_INFO_64, $0, &count, &object)
                }
            }
            if kr != KERN_SUCCESS { break }
            let start = min(UInt64(addr), guestLo)
            if start > prevEnd && start - prevEnd >= 64 << 20 {
                holes.append((prevEnd, start - prevEnd))
            }
            prevEnd = max(prevEnd, UInt64(addr) + UInt64(rsize))
            addr = vm_address_t(prevEnd)
        }
        if !holes.isEmpty {
            log("[jit-pool] free holes ≥64 MB: " + holes.map {
                "0x\(String($0.base, radix: 16))+\($0.size >> 20) MB"
            }.joined(separator: " "))
        }
        let largest = holes.map { $0.size }.max() ?? 0
        if largest < UInt64(poolSize) {
            let fit = Int(largest) & ~((16 << 20) - 1)
            if fit >= 256 << 20 {
                log("[jit-pool] no hole fits \(poolSize >> 20) MB — shrinking to \(fit >> 20) MB.", level: .warning)
                poolSize = fit
            } else {
                log("[jit-pool] largest hole is only \(largest >> 20) MB; the request may fail.", level: .warning)
            }
        }

        // First-fit would prefer a lower hole that fits. Plug those for the
        // duration of the request when a hole above the window can take the
        // pool, so the RX pages land in the measured-good gap.
        var plugs: [(vm_address_t, vm_size_t)] = []
        let aboveFits = holes.contains { $0.base + $0.size > UInt64(earlyPoolBase) && $0.size >= UInt64(poolSize) }
        if earlyPoolBase != 0 && windowHeld && aboveFits {
            for hole in holes where hole.base + hole.size <= UInt64(earlyPoolBase) && hole.size >= UInt64(poolSize) {
                var base = vm_address_t(hole.base)
                if vm_allocate(mach_task_self_, &base, vm_size_t(hole.size), 0) == KERN_SUCCESS && UInt64(base) == hole.base {
                    plugs.append((base, vm_size_t(hole.size)))
                    log("[jit-pool] plugged lower hole 0x\(String(hole.base, radix: 16))+\(hole.size >> 20) MB.")
                } else if UInt64(base) != hole.base {
                    vm_deallocate(mach_task_self_, base, vm_size_t(hole.size))
                }
            }
        }

        var rx: UnsafeMutableRawPointer?
        var requestUnanswered = false
        for attempt in 0..<3 {
            guard let prepared = jit26_prepare_region(nil, poolSize),
                  Int(bitPattern: prepared) != 0 else {
                requestUnanswered = true
                log("[jit-pool] the debugger did not grant RX memory (attempt \(attempt + 1)).", level: .error)
                break
            }
            let base = UInt64(UInt(bitPattern: prepared))
            let inGuestWindow = base + UInt64(poolSize) > guestLo && base < guestHi
            let hitsExeWindow = base < exeWinBase + exeWinSize && base + UInt64(poolSize) > exeWinBase
            if base >= goodLow && !inGuestWindow && !hitsExeWindow {
                rx = prepared
                break
            }
            let why = base < goodLow ? "below the FEX floor"
                : (hitsExeWindow ? "would swallow the executable window" : "inside the guest 64 GB window")
            log("[jit-pool] rejected placement 0x\(String(base, radix: 16)) (\(why)); re-rolling.", level: .error)
            vm_deallocate(mach_task_self_, vm_address_t(base), vm_size_t(poolSize))
        }
        for (base, size) in plugs { vm_deallocate(mach_task_self_, base, size) }

        guard let rx else {
            if requestUnanswered && !debuggerAttached {
                failure = "JIT is switched on, but no debugger is attached to grant the engine's memory. "
                    + "Enable JIT again (Settings → JIT setup or the Enable JIT button) and keep the debugger attached until the game starts."
            } else if requestUnanswered {
                failure = "The debugger could not grant the JIT memory the engine needs. Restart Windoz, enable JIT and try again."
            } else {
                failure = "The JIT memory landed at an address the engine cannot use. Restart Windoz, enable JIT and try again."
            }
            log("[jit-pool] allocation failed: \(failure ?? "unknown")", level: .error)
            return false
        }

        let rxBase = UInt64(UInt(bitPattern: rx))
        log("[jit-pool] RX granted at 0x\(String(rxBase, radix: 16)) (\(poolSize >> 20) MB).")

        // The writable alias is data-only, so its placement is free. Ask high
        // first (keeps the scarce low gap for RX), then beside the pool, then
        // wherever the kernel chooses.
        var rwAddr: vm_address_t = 0
        var currentProt: vm_prot_t = 0
        var maxProt: vm_prot_t = 0
        var remap: kern_return_t = KERN_NO_SPACE
        for hint in [vm_address_t(guestLo), vm_address_t(rxBase + UInt64(poolSize)), 0] {
            rwAddr = hint
            remap = vm_remap(mach_task_self_, &rwAddr, vm_size_t(poolSize), 0, VM_FLAGS_ANYWHERE,
                             mach_task_self_, vm_address_t(rxBase), 0,
                             &currentProt, &maxProt, VM_INHERIT_NONE)
            if remap != KERN_NO_SPACE { break }
        }
        guard remap == KERN_SUCCESS else {
            failure = "The engine's JIT memory could not be mirrored read/write (vm_remap \(remap)). Restart Windoz and try again."
            log("[jit-pool] \(failure ?? "")", level: .error)
            vm_deallocate(mach_task_self_, vm_address_t(rxBase), vm_size_t(poolSize))
            return false
        }
        let protect = vm_protect(mach_task_self_, rwAddr, vm_size_t(poolSize), 0, VM_PROT_READ | VM_PROT_WRITE)
        guard protect == KERN_SUCCESS else {
            failure = "The engine's JIT memory could not be made writable (vm_protect \(protect)). Restart Windoz and try again."
            log("[jit-pool] \(failure ?? "")", level: .error)
            vm_deallocate(mach_task_self_, rwAddr, vm_size_t(poolSize))
            vm_deallocate(mach_task_self_, vm_address_t(rxBase), vm_size_t(poolSize))
            return false
        }
        let rw = UnsafeMutableRawPointer(bitPattern: UInt(rwAddr))!

        // The pool is where all guest code lives; without the ledger exemption
        // every written page counts against phys_footprint (jetsam kills).
        let exempt = jit_make_region_no_footprint(rw, poolSize, "windoz-pool-RW-alias")
        log("[jit-pool] no-footprint ledger: \(exempt ? "applied" : "refused (non-fatal)")",
            level: exempt ? .success : .warning)

        // Publish exactly what the Wine fork reads. These three names are the
        // engine's contract — virtual_ios.c does nothing without them.
        setenv("WINE_IOS_JIT_RX", String(rxBase, radix: 16), 1)
        setenv("WINE_IOS_JIT_RW", String(rwAddr, radix: 16), 1)
        setenv("WINE_IOS_JIT_SIZE", String(poolSize, radix: 16), 1)

        pool = (rx, rw, poolSize)
        log("[jit-pool] ready: RX=0x\(String(rxBase, radix: 16)), RW=0x\(String(UInt64(rwAddr), radix: 16)), "
            + "\(poolSize >> 20) MB, WINE_IOS_JIT_* published.", level: .success)
        return true
    }

    /// Madeira detaches the debugger right after the pool exists and before
    /// Wine starts: every executable page comes from the pool, and a StikDebug
    /// that departs later (its CPU budget is ~50 s) stalls the whole app.
    static func detachDebugger() {
        guard isReady else { return }
        guard windoz_jit_debugger_attached() != 0 else {
            log("[jit-pool] debugger already gone; nothing to detach.")
            return
        }
        jit26_detach()
        setenv("MADEIRA_DETACHED", "1", 1)
        log("[jit-pool] debugger detached; the pool keeps serving the session.", level: .success)
    }

    private static func hex(_ pointer: UnsafeMutableRawPointer) -> String {
        "0x" + String(UInt64(UInt(bitPattern: pointer)), radix: 16)
    }

    private static func log(_ text: String, level: LogLine.Level = .info) {
        EngineLogStream.shared.append(text, level: level)
    }
}
