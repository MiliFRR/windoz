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

# --- Wine: ARM64EC PE tree (configures wine/build-arm64ec on first run)
run bash build/wine-pe/build-ntdll.sh
# widl-generated public headers (dwrite.h etc.) live in the build tree only
# after the corresponding DLL target builds:
run make -C wine/build-arm64ec -j "$JOBS" dlls/dwrite
# unix-side scripts read wine/build-macos — alias it to the arm64ec tree:
[ -e wine/build-macos ] || ln -s build-arm64ec wine/build-macos
run bash build/wine-pe/build-modules.sh

# --- wineserver: base archive from source, then Madeira's patch/replace pass
run bash "$ROOT/scripts/build-wineserver-base.sh"
run bash build/wineserver/build.sh

# --- Wine unix sides (need gnutls/ffmpeg/freetype + the wine build trees)
run bash build/ntdll-unix/build.sh
run bash build/win32u-unix/build.sh

# --- FEX
run bash build/fex-ios/build.sh
run bash build/fex-arm64ec/build.sh

# --- DXMT unix side (LLVM headers + vendored converter via deps.sh)
run bash build/dxmt-ios/build.sh
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

# --- Madeira Dock (becomes Doz Dock in Phase 5). Non-fatal in Phase 0:
# without it the Steam library stays off, but the app builds and runs.
if bash build/madeira-dock/build.sh; then
  echo "dock built"
else
  echo "::warning::Madeira Dock build failed — Steam library stays off (tolerated in Phase 0)"
fi
