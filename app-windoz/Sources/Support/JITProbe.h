#ifndef JITPROBE_H
#define JITPROBE_H

// Windoz JIT readiness probe — original code.
//
// The probe must be safe to call at any moment, JIT on or off. It therefore
// never maps executable memory and never executes anything: on iOS 26 the
// platform rejects execution of RX pages an app mapped itself (the engine's
// JITAllocator documents the "fault loop" that produces: "TXM rejected
// self-mapped RX pages"), and a jit26_* BRK with no debugger attached kills
// the process outright (EXC_BREAKPOINT in jit26_prepare_region).
//
// Readiness mirrors the engine's own rule (Madeira's StikJITHelper.ready):
// CS_DEBUGGED is set AND a debugger is attached right now to answer the BRK
// protocol. Neither check touches executable memory.
int windoz_jit_probe(void);

// P_TRACED for this process (via sysctl): 1 while a debugger is attached.
// CS_DEBUGGED is sticky and stays set after a debugger leaves; this is the
// live half of the readiness rule (Madeira calls the same check
// isDebuggerAttached()).
int windoz_jit_debugger_attached(void);

#endif
