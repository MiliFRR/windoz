#!/usr/bin/env bash
# Create app/Madeira/libdxmt_combined.a = libdxmt_unix.a + the LLVM static
# archives that airconv (the DXBC -> AIR shader compiler) needs.
#
# Madeira's build/dxmt-ios/build.sh only REFRESHES this archive when it already
# exists; nothing upstream creates it on a clean checkout, and the Xcode app
# target links it. Madeira's build/dxmt-ios/README.md prescribes what to put in
# it:
#
#   xcrun -sdk iphoneos libtool -static -o libdxmt_combined.a \
#       obj/*.o ../../toolchains/llvm-ios-build/lib/*.a
#
# i.e. the DXMT objects plus EVERY LLVM iOS archive. That is deliberate: a
# static archive is linked member-by-member, so an unused archive costs nothing
# but the link pulls exactly the members the referenced objects need — including
# the LLVM members that are only reachable *from* other LLVM members (the new
# pass manager is one such chain: dxmt::runOptimizationPasses ->
# llvm::PassBuilder -> LLVM's own analyses/passes).
#
# An earlier version of this script tried to be clever: compute the archive
# closure from libdxmt_unix.a's undefined symbols and include only those. That
# produced a linkable-looking 55 MB archive that still failed the app link:
#
#   Undefined symbols for architecture arm64:
#     "llvm::PassBuilder::PassBuilder(llvm::TargetMachine*, ...)",
#     "llvm::PassBuilder::registerModuleAnalyses(...)", ... 
#     referenced from: dxmt::runOptimizationPasses(llvm::Module&) in airconv_context.o
#
# so we now follow the documented command exactly. The closure output is still
# printed as information (a visible record of what the direct dependency set
# looks like), but it no longer decides what goes in.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/madeira"

UNIX_A="build/dxmt-ios/libdxmt_unix.a"
STAGE="build/dxmt-ios/libdxmt_combined.a"
COMBINED="app/Madeira/libdxmt_combined.a"
LIBS="toolchains/llvm-ios-build/lib"

[ -f "$UNIX_A" ] || { echo "ERROR: $UNIX_A missing (build/dxmt-ios/build.sh must run first)" >&2; exit 1; }
[ -d "$LIBS" ] || { echo "ERROR: $LIBS missing (LLVM must be built first)" >&2; exit 1; }

# airconv compiles its AIR pipeline with LLVM's new pass manager; those objects
# live in libLLVMPasses.a. Fail loudly rather than build a combined archive that
# cannot link (CI run: this exact archive was missing from the selection).
if [ ! -f "$LIBS/libLLVMPasses.a" ]; then
  echo "ERROR: $LIBS/libLLVMPasses.a missing — did the LLVM iOS build produce all libraries?" >&2
  ls -1 "$LIBS" >&2 || true
  exit 1
fi

# Informational: which LLVM archives a symbol closure from libdxmt_unix.a alone
# would have picked. Not used for the archive (see the header comment).
UNIX_A="$UNIX_A" LIBS="$LIBS" python3 - <<'PY' || echo "note: closure report failed (non-fatal)"
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

print("=== LLVM archives a direct closure from %s would pick (informational) ===" % unix.name)
for a in selected:
    print("  + " + a.name)
print("  (%d of %d archives; the combined archive includes ALL of them)" % (len(selected), len(archives)))
PY

ALL_LLVM=("$LIBS"/*.a)
echo "=== combining $(basename "$UNIX_A") + ${#ALL_LLVM[@]} LLVM archives ==="
mkdir -p "$(dirname "$STAGE")"
rm -f "$STAGE"
xcrun -sdk iphoneos libtool -static -o "$STAGE" "$UNIX_A" "${ALL_LLVM[@]}"
xcrun -sdk iphoneos ranlib "$STAGE"
cp "$STAGE" "$COMBINED"
echo "combined archive: $(wc -c < "$COMBINED" | tr -d ' ') bytes -> app/Madeira/libdxmt_combined.a"
