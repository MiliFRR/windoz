// Windoz JIT readiness probe — original code. See JITProbe.h.
#include "JITProbe.h"

// Engine symbols (JITAllocator.c is compiled into this target):
//   jit_check_debugged()  — the sticky CS_DEBUGGED flag.
#include "../../../madeira/app/Madeira/JITAllocator.h"

#include <string.h>
#include <sys/proc.h>
#include <sys/sysctl.h>
#include <unistd.h>

int windoz_jit_debugger_attached(void) {
    struct kinfo_proc info;
    size_t size = sizeof info;
    int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid() };
    memset(&info, 0, sizeof info);
    if (sysctl(mib, 4, &info, &size, NULL, 0) != 0) return 0;
    return (info.kp_proc.p_flag & P_TRACED) != 0;
}

int windoz_jit_probe(void) {
    return jit_check_debugged() && windoz_jit_debugger_attached();
}
