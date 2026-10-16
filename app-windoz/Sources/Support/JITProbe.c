// Windoz JIT probe — original code. See JITProbe.h.
#include "JITProbe.h"

#include <sys/mman.h>
#include <string.h>

int windoz_jit_probe(void) {
    void *p = mmap(NULL, 4096, PROT_READ | PROT_WRITE | PROT_EXEC,
                   MAP_ANONYMOUS | MAP_PRIVATE, -1, 0);
    if (p == MAP_FAILED) return 0;

    // ARM64: mov w0, #42 ; ret
    unsigned char code[] = { 0x40, 0x05, 0x80, 0x52, 0xC0, 0x03, 0x5F, 0xD6 };
    memcpy(p, code, sizeof code);
    __builtin___clear_cache((char *)p, (char *)p + 4096);

    int (*fn)(void) = (int (*)(void))p;
    int result = fn();
    munmap(p, 4096);
    return result == 42;
}
