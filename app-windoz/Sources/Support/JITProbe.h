#ifndef JITPROBE_H
#define JITPROBE_H

// Windoz JIT probe — original code.
// Maps one RWX page, writes a tiny ARM64 function into it and executes it.
// On non-jailbroken iOS a process may only create executable memory while a
// debugger is attached, so this succeeds exactly when JIT is available.
int windoz_jit_probe(void);

#endif
