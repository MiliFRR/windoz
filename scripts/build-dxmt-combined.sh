#!/usr/bin/env bash
# Create app/Madeira/libdxmt_combined.a = libdxmt_unix.a + the LLVM static
# archives that airconv (the DXBC -> AIR shader compiler) needs.
#
# Madeira's build/dxmt-ios/build.sh only REFRESHES this archive when it
# already exists; nothing upstream creates it on a clean checkout, and the
# Xcode app target links it (CI runs: see README watch-item). The LLVM
# archives are chosen by SYMBOL CLOSURE: start from libdxmt_unix.a's
# undefined symbols, add every archive that defines one, repeat until stable.
# Static archives are linked member-by-member, so including an archive is
# always safe — the final app link only pulls the members it references.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/madeira"
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"

UNIX_A="build/dxmt-ios/libdxmt_unix.a"
STAGE="build/dxmt-ios/libdxmt_combined.a"
COMBINED="app/Madeira/libdxmt_combined.a"
LIBS="toolchains/llvm-ios-build/lib"

[ -f "$UNIX_A" ] || { echo "ERROR: $UNIX_A missing (build/dxmt-ios/build.sh must run first)" >&2; exit 1; }
[ -d "$LIBS" ] || { echo "ERROR: $LIBS missing (LLVM must be built first)" >&2; exit 1; }

if [ -f "$STAGE" ] || [ -f "$COMBINED" ]; then
  echo "libdxmt_combined.a already exists (dxmt-ios/build.sh refreshed it in place)"
  [ -f "$STAGE" ] && cp "$STAGE" "$COMBINED"
  exit 0
fi

echo "=== computing LLVM archive closure for airconv ==="
SELECTED=$(UNIX_A="$UNIX_A" LIBS="$LIBS" python3 - <<'PY'
import subprocess, pathlib, os, sys

libs_dir = pathlib.Path(os.environ["LIBS"])
unix = pathlib.Path(os.environ["UNIX_A"])

def symbols(ar):
    p = subprocess.run(["nm", str(ar)], capture_output=True, text=True)
    defined, undefined = set(), set()
    for line in p.stdout.splitlines():
        if not line.strip() or ".o:" in line:
            continue
        parts = line.split()
        if len(parts) < 2:
            continue
        name = parts[-1]
        typ = parts[-2] if len(parts) >= 3 else parts[0]
        if typ == "U":
            undefined.add(name)
        else:
            defined.add(name)
    return defined, undefined

d0, u0 = symbols(unix)
resolved = set(d0)
pending = set(u for u in u0 if u not in resolved)

archives = sorted(libs_dir.glob("lib*.a"))
info = {}
for a in archives:
    try:
        info[a] = symbols(a)
    except Exception as e:
        print("warning: nm failed on %s: %s" % (a.name, e), file=sys.stderr)

selected = []
changed = True
while changed and pending:
    changed = False
    for a in archives:
        if a in selected:
            continue
        d, u = info.get(a, (set(), set()))
        if pending & d:
            selected.append(a)
            resolved |= d
            pending -= d
            pending |= (u - resolved)
            changed = True

if not selected:
    print("ERROR: symbol closure selected no LLVM archives - unexpected", file=sys.stderr)
    sys.exit(1)
for a in selected:
    print("  + " + a.name, file=sys.stderr)
print(" ".join(str(a) for a in selected))
PY
)

mkdir -p "$(dirname "$STAGE")"
# shellcheck disable=SC2086
xcrun -sdk iphoneos libtool -static -o "$STAGE" "$UNIX_A" $SELECTED
cp "$STAGE" "$COMBINED"
echo "combined archive: $(wc -c < "$COMBINED" | tr -d ' ') bytes -> app/Madeira/libdxmt_combined.a"
