#!/usr/bin/env bash
# Build the native runtime chain in the order Madeira docs/BUILDING.md
# prescribes: GnuTLS, FFmpeg, FEX (unix + ARM64EC), Wine (unix + ARM64EC PE),
# DXMT (unix + ARM64EC PE), Wine Mono, in-app pairing, native D3D12, stub and
# fault-repair DLLs, and (non-fatally in Phase 0) Madeira Dock.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/madeira"

run() { echo "=== $* ==="; "$@"; }

run bash build/gnutls-ios/build.sh
run bash build/ffmpeg/build.sh
run bash build/fex-ios/build.sh
run bash build/fex-arm64ec/build.sh
run bash build/ntdll-unix/build.sh
run bash build/wineserver/build.sh
run bash build/win32u-unix/build.sh
run bash build/wine-pe/build-ntdll.sh
run bash build/wine-pe/build-modules.sh
run bash build/dxmt-ios/build.sh

# DXMT PE side (meson + ninja), per docs/BUILDING.md step 4.
if [ ! -d dxmt/build-arm64ec ]; then
  meson setup dxmt/build-arm64ec dxmt \
    -Dbuildtype=release \
    -Dwine_build_path=../../wine/build-arm64ec \
    --cross-file=dxmt/build-arm64ec-win.txt
fi
run ninja -C dxmt/build-arm64ec src/winemetal/winemetal.dll
find dxmt/build-arm64ec -name "winemetal.dll" -exec cp {} app/Madeira/arm64ec-windows/ \;
ninja -C dxmt/build-arm64ec src/d3d11/d3d11.dll || \
  echo "::warning::d3d11.dll target name differs — will verify against the repo"
find dxmt/build-arm64ec -name "d3d11.dll" -exec cp {} app/Madeira/arm64ec-windows/ \; 2>/dev/null || true

run bash build/wine-mono/fetch.sh
run bash build/rppairing-ios/build.sh
run bash build/madeira-d3d12/fetch-converter.sh
run bash build/madeira-d3d12/build-pe.sh

run python3 tools/build-stub-dlls.py wine build/stub-dlls \
  "toolchains/llvm-mingw-20260421-ucrt-macos-universal/bin/arm64ec-w64-mingw32-clang" \
  "toolchains/llvm-mingw-20260421-ucrt-macos-universal/bin/llvm-readobj" \
  app/Madeira/arm64ec-windows

run bash build/faultrep/build.sh

# Madeira Dock — becomes "Doz Dock" in Phase 5. Non-fatal in Phase 0: without
# it the Steam library stays off, but the app builds and runs local games.
if bash build/madeira-dock/build.sh; then
  echo "dock built"
else
  echo "::warning::Madeira Dock build failed — Steam library stays off (tolerated in Phase 0)"
fi
