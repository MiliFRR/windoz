#!/usr/bin/env bash
# Replicates Madeira's build/wine-pe/build-ntdll.sh, but builds ONLY the PE
# target (dlls/ntdll/arm64ec-windows/ntdll.dll). The stock script runs
# `make -C dlls/ntdll`, whose default target ALSO builds the host unix side
# (ntdll.so) — and that cannot link on a clean checkout because it references
# Madeira's private iOS symbol (_ios_avail_phys) from their replaced unix
# side (CI run #8). The PE target alone is what the app needs; the strip and
# pad-to-SizeOfImage+0x50000 post-processing below is copied verbatim from
# the upstream script.
set -euo pipefail

R="$(cd "$(dirname "$0")/.." && pwd)"
M="$R/madeira"
TC="$M/toolchains/llvm-mingw-20260421-ucrt-macos-universal/bin"
export PATH="$TC:$PATH"
if command -v brew >/dev/null 2>&1; then
    BISON_BIN="$(brew --prefix bison 2>/dev/null || true)/bin"
    if [ -x "$BISON_BIN/bison" ]; then export PATH="$BISON_BIN:$PATH"; fi
fi
B="$M/wine/build-arm64ec"
JOBS="$(sysctl -n hw.ncpu)"

if [ ! -f "$B/config.status" ]; then
    mkdir -p "$B"
    (cd "$B" && ../configure --enable-archs=arm64ec --without-x --disable-tests --enable-winegstreamer)
fi

make -C "$B" -j "$JOBS" dlls/ntdll/arm64ec-windows/ntdll.dll

SRC="$B/dlls/ntdll/arm64ec-windows/ntdll.dll"
OUT="$M/app/Madeira/arm64ec-windows/ntdll.dll"
cp "$SRC" "$OUT.tmp"
"$TC/arm64ec-w64-mingw32-strip" "$OUT.tmp"
python3 - "$OUT.tmp" <<'PY'
import struct, sys
p = sys.argv[1]; d = open(p, 'rb').read()
pe = struct.unpack_from('<I', d, 0x3c)[0]
soi = struct.unpack_from('<I', d, pe + 24 + 56)[0]     # OptionalHeader.SizeOfImage
target = soi + 0x50000
if len(d) > target:
    raise SystemExit("stripped ntdll is %d bytes, already larger than the "
                     "target SizeOfImage(%d) + 0x50000 = %d -- the padding "
                     "assumption no longer holds, do not guess"
                     % (len(d), soi, target))
pad = target - len(d)
with open(p, 'ab') as f:
    f.write(b'\0' * pad)
final = len(open(p, 'rb').read())
if final != target:
    raise SystemExit("padding produced %d bytes, expected %d" % (final, target))
print("ntdll.dll: stripped %d + pad %d = %d bytes (SizeOfImage %d + 0x50000)"
      % (len(d), pad, final, soi))
PY
mv "$OUT.tmp" "$OUT"
ls -l "$OUT"
