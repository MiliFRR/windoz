// Windoz — original implementation of the Winios main-stall diagnostics hook.
// Winios.m's heartbeat calls this when the main thread stalls. Madeira's
// implementation is not in the public repository, so this is an original,
// self-contained dumper: walk the task's Mach threads, suspend each briefly,
// report pc/lr symbolised through dladdr, resume. Logging only.
#include <dlfcn.h>
#include <mach/mach.h>
#include <pthread.h>
#include <stdio.h>
#include <string.h>

void ios_dump_all_thread_stacks(void) {
    thread_act_array_t threads;
    mach_msg_type_number_t count;
    if (task_threads(mach_task_self(), &threads, &count) != KERN_SUCCESS) return;

    /* mach_thread_self() returns a thread port, not a thread array: compare it
     * against the per-thread ports below so the dumper never suspends itself. */
    mach_port_t self_port = mach_thread_self();
    dprintf(2, "[windoz] thread stack dump (%u threads):\n", count);

    for (mach_msg_type_number_t i = 0; i < count; i++) {
        if (threads[i] == self_port) {
            dprintf(2, "  #%u (this dumper)\n", i);
            mach_port_deallocate(mach_task_self(), threads[i]);
            continue;
        }
        thread_basic_info_data_t info;
        mach_msg_type_number_t ic = THREAD_BASIC_INFO_COUNT;
        const char *state = "?";
        if (thread_info(threads[i], THREAD_BASIC_INFO, (thread_info_t)&info, &ic) == KERN_SUCCESS) {
            switch (info.run_state) {
                case TH_STATE_RUNNING: state = "running"; break;
                case TH_STATE_WAITING: state = "waiting"; break;
                case TH_STATE_STOPPED: state = "suspended"; break;
                case TH_STATE_HALTED: state = "halted"; break;
            }
        }
        if (thread_suspend(threads[i]) != KERN_SUCCESS) {
            dprintf(2, "  #%u %s (state unavailable)\n", i, state);
            mach_port_deallocate(mach_task_self(), threads[i]);
            continue;
        }
        arm_thread_state64_t st;
        mach_msg_type_number_t sc = ARM_THREAD_STATE64_COUNT;
        if (thread_get_state(threads[i], ARM_THREAD_STATE64, (thread_state_t)&st, &sc) == KERN_SUCCESS) {
            uintptr_t pc = (uintptr_t)arm_thread_state64_get_pc(st);
            const char *where = "?";
            char buf[128];
            Dl_info di = {0};
            if (dladdr((const void *)pc, &di) != 0 && di.dli_sname) {
                where = di.dli_sname;
            } else if (di.dli_fname) {
                const char *b = strrchr(di.dli_fname, '/');
                snprintf(buf, sizeof buf, "%s+0x%lx", b ? b + 1 : di.dli_fname,
                         (unsigned long)(pc - (uintptr_t)di.dli_fbase));
                where = buf;
            }
            pthread_t pt = pthread_from_mach_thread_np(threads[i]);
            char name[64] = "";
            if (pt) pthread_getname_np(pt, name, sizeof name);
            dprintf(2, "  #%u %s pc=%p (%s) name=%s\n", i, state, (void *)pc, where, name);
        } else {
            dprintf(2, "  #%u %s (no state)\n", i, state);
        }
        thread_resume(threads[i]);
        mach_port_deallocate(mach_task_self(), threads[i]);
    }
    mach_port_deallocate(mach_task_self(), self_port);
    vm_deallocate(mach_task_self(), (vm_address_t)threads, count * sizeof(*threads));
}
