#!/usr/bin/env bash
# Build the native runtime chain. The order respects dependencies discovered
# by auditing every script (see README "Known issues"):
#   - wine/build-arm64ec must be configured (build-ntdll.sh) and its
#     widl-generated headers built (dlls/dwrite) before the unix-side builds;
#   - wine/build-macos must exist before ntdll-unix / wineserver (the unix
#     scripts read config.h and includes from it) — aliased to the arm64ec
#     tree, which has the same Darwin-host configuration;
#   - freetype must be cloned + built before win32u-unix;
#   - libwineserver.a needs a BASE archive compiled from wine/server/*.c
#     (none is tracked in the repo) before build/wineserver/build.sh patches it;
#   - the DXMT unix build needs LLVM built and the vendored Metal Shader
#     Converter (deps.sh verifies tracked files; Apple's installer package is
#     NOT needed, so fetch-converter.sh is deliberately not run here);
#   - the DXMT PE build needs the wine arm64ec tree; madeira-d3d12 build-pe
#     needs the DXMT PE winemetal import library.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/madeira"
export PATH="$ROOT/madeira/toolchains/llvm-mingw-20260421-ucrt-macos-universal/bin:$PATH"
# Wine's configure needs bison 3; macOS ships 2.3, so prefer Homebrew's.
if command -v brew >/dev/null 2>&1; then
  BISON_BIN="$(brew --prefix bison 2>/dev/null || true)/bin"
  if [ -d "$BISON_BIN" ]; then export PATH="$BISON_BIN:$PATH"; fi
fi
JOBS="$(sysctl -n hw.ncpu)"

run() { echo "=== $* ==="; "$@"; }

# --- crypto + media libraries (tracked tarballs, hash-verified, no network)
run bash build/gnutls-ios/build.sh
run bash build/ffmpeg/build.sh

# --- freetype for win32u's font engine (not vendored; shallow clone pinned tag)
if [ ! -d research/freetype ]; then
  run git clone --depth 1 --branch VER-2-13-3 \
    https://github.com/freetype/freetype.git research/freetype
fi
run bash build/freetype-ios/build.sh

# --- Wine: ARM64EC PE tree. ntdll is built via our PE-only replica (the
# stock script's `make -C dlls/ntdll` also builds the host unix ntdll.so,
# which cannot link on a clean checkout — see README, run #8):
run bash "$ROOT/scripts/build-wine-ntdll.sh"
# widl-generated public headers (dwrite.h) live in the build tree only after
# the corresponding PE DLL target builds (file target, NOT the directory —
# the directory default would also build dwrite's unix side):
run make -C wine/build-arm64ec -j "$JOBS" dlls/dwrite/arm64ec-windows/dwrite.dll
# unix-side scripts read wine/build-macos — alias it to the arm64ec tree:
[ -e wine/build-macos ] || ln -s build-arm64ec wine/build-macos
run bash build/wine-pe/build-modules.sh

# --- wineserver: base archive from source, then Madeira's patch/replace pass
run bash "$ROOT/scripts/build-wineserver-base.sh"
run bash build/wineserver/build.sh

# --- Wine unix sides (need gnutls/ffmpeg/freetype + the wine build trees)
# SDK 26.2 (macos-15 image) removed rusage_info_v6.ri_page_wait_time_mach,
# which server_ios.c's process-stats log line uses. Patch it to 0 (cosmetic
# instrumentation, idempotent); the full .err dump below catches anything else.
python3 - <<'PY'
import pathlib
p = pathlib.Path("build/ntdll-unix/server_ios.c")
s = p.read_text()
n = s.replace(
    "XP_MS( ru.ri_page_wait_time_mach - pru.ri_page_wait_time_mach )",
    "XP_MS( 0 )")
if n != s:
    p.write_text(n)
    print("patched server_ios.c: ri_page_wait_time_mach absent in this SDK; profile term zeroed")
PY
if ! bash build/ntdll-unix/build.sh; then
  echo "=== ntdll-unix per-file compile errors ==="
  for e in build/ntdll-unix/obj/*.err; do
    if [ -s "$e" ]; then echo "--- ${e##*/}"; head -400 "$e"; fi
  done
  exit 1
fi
if ! bash build/win32u-unix/build.sh; then
  echo "=== win32u-unix per-file compile errors ==="
  for e in build/win32u-unix/obj/*.err; do
    if [ -s "$e" ]; then echo "--- ${e##*/}"; head -400 "$e"; fi
  done
  exit 1
fi

# --- FEX
# fex-ios/build.sh configures on first run, but two of FEX's CMake defaults
# break under an iOS cross-configure on a clean machine (CI run #13):
#  - CMAKE_SYSTEM_PROCESSOR comes up EMPTY -> "Unsupported processor type ."
#  - TUNE_CPU=native probes /proc/cpuinfo, which "aborts the configure on
#    macOS" (FEX's own comment in build/fex-arm64ec/build.sh)
# Pre-configure here with exactly the script's options plus those two fixes;
# the script then skips its own configure and builds.
if [ ! -f FEX/build-ios/CMakeCache.txt ]; then
  cmake -S FEX -B FEX/build-ios \
    -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_SYSROOT=iphoneos -DCMAKE_OSX_DEPLOYMENT_TARGET=17.0 \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_TESTING=OFF -DBUILD_THUNKS=OFF -DBUILD_FEXCONFIG=OFF \
    -DBUILD_FEX_LINUX_TESTS=OFF -DENABLE_FEX_ALLOCATOR=OFF \
    -DENABLE_ASSERTIONS=OFF -DENABLE_CLANG_THUNKS=ON -DENABLE_CCACHE=ON \
    -DCMAKE_SYSTEM_PROCESSOR=arm64 -DTUNE_CPU=cortex-a78
fi
run bash build/fex-ios/build.sh
# fex-arm64ec: pre-configure with the script's exact options (BUILDING.md:
# "the options the madeira-bcd fork's macOS CI has built xtajit64.dll with
# since 2026-09-26") plus CMAKE_DISABLE_FIND_PACKAGE for fmt and range-v3 —
# CI run #14: Homebrew's fmt was found by find_package and its macOS dylib
# cannot satisfy the Windows-style cross build ("IMPORTED_IMPLIB not set for
# imported target fmt::fmt"); disabling the search makes FEX use its bundled
# copies, which is what machines without those brew formulae get anyway.
if [ ! -f FEX/build-arm64ec/CMakeCache.txt ]; then
  cmake -S FEX -B FEX/build-arm64ec -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_TOOLCHAIN_FILE="$PWD/FEX/Data/CMake/toolchain_mingw.cmake" \
    -DMINGW_TRIPLE=arm64ec-w64-mingw32 -DTUNE_CPU=cortex-a78 \
    -DFEX_IOS_HOST_BUILD=ON -DCMAKE_C_FLAGS=-DFEX_IOS_HOST=1 \
    -DCMAKE_CXX_FLAGS=-DFEX_IOS_HOST=1 -DCMAKE_ASM_FLAGS=-DFEX_IOS_HOST=1 \
    -DENABLE_LTO=OFF -DENABLE_FEX_ALLOCATOR=ON -DENABLE_JEMALLOC_GLIBC_ALLOC=ON \
    -DENABLE_OFFLINE_RUNTIME=ON -DBUILD_FEXCONFIG=ON -DENABLE_CLANG_THUNKS=ON \
    -DENABLE_CCACHE=ON -DBUILD_TESTING=OFF -DBUILD_THUNKS=OFF -DENABLE_ASSERTIONS=OFF \
    -DCMAKE_DISABLE_FIND_PACKAGE_fmt=TRUE -DCMAKE_DISABLE_FIND_PACKAGE_range-v3=TRUE
fi
run bash build/fex-arm64ec/build.sh

# --- DXMT unix side (LLVM headers + vendored converter via deps.sh)
if ! bash build/dxmt-ios/build.sh; then
  echo "=== dxmt-ios per-file compile errors ==="
  for e in build/dxmt-ios/obj/*.err; do
    if [ -s "$e" ]; then echo "--- ${e##*/}"; head -60 "$e"; fi
  done
  exit 1
fi
run bash "$ROOT/scripts/build-dxmt-combined.sh"
# --- DXMT PE side (needs the wine arm64ec tree)
if [ ! -d dxmt/build-arm64ec ]; then
  run meson setup dxmt/build-arm64ec dxmt \
    -Dbuildtype=release \
    -Dwine_build_path=../../wine/build-arm64ec \
    --cross-file=dxmt/build-arm64ec-win.txt
fi
run ninja -C dxmt/build-arm64ec src/winemetal/winemetal.dll
find dxmt/build-arm64ec -name "winemetal.dll" -exec cp {} app/Madeira/arm64ec-windows/ \;
ninja -C dxmt/build-arm64ec src/d3d11/d3d11.dll || \
  echo "::warning::d3d11.dll ninja target name differs — verify against the dxmt repo"
find dxmt/build-arm64ec -name "d3d11.dll" -exec cp {} app/Madeira/arm64ec-windows/ \; 2>/dev/null || true

# --- Wine Mono (Debug configuration's Bundle phase needs it fetched)
run bash build/wine-mono/fetch.sh

# --- In-app JIT pairing library (Rust, aarch64-apple-ios)
run bash build/rppairing-ios/build.sh

# --- Native D3D12 runtime (needs the DXMT PE winemetal import library)
run bash build/madeira-d3d12/build-pe.sh

# --- Stub DLLs + faultrep
run python3 tools/build-stub-dlls.py wine build/stub-dlls \
  "toolchains/llvm-mingw-20260421-ucrt-macos-universal/bin/arm64ec-w64-mingw32-clang" \
  "toolchains/llvm-mingw-20260421-ucrt-macos-universal/bin/llvm-readobj" \
  app/Madeira/arm64ec-windows
run bash build/faultrep/build.sh

# The Xcode project references the i386-windows folder (32-bit WoW64), which
# is not tracked and is deliberately NOT built yet (32-bit games are deferred;
# the whole wine-i386 + fex-wow64 chain is UNVERIFIED upstream). An empty
# folder satisfies the folder reference; 64-bit games are unaffected.
mkdir -p app/Madeira/i386-windows

# --- Madeira Dock (becomes Doz Dock in Phase 5). Non-fatal in Phase 0:
# without it the Steam library stays off, but the app builds and runs.
if bash build/madeira-dock/build.sh; then
  echo "dock built"
else
  echo "::warning::Madeira Dock build failed — Steam library stays off (tolerated in Phase 0)"
fi
