#!/usr/bin/env bash
# Build LLVM for iOS, following Madeira docs/BUILDING.md ("inputs that are not
# in the repository"). The configure flags are the ones recorded from the
# original CMakeCache. Cached across CI runs keyed on LLVM_COMMIT.
set -euo pipefail

LLVM_COMMIT="${LLVM_COMMIT:-8dfdcc7b7bf66834a761bd8de445840ef68e4d1a}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/madeira"
mkdir -p toolchains
cd toolchains

if [ ! -d llvm-project/.git ]; then
  # Partial clone: metadata only, blobs fetched on demand at checkout.
  git clone --filter=blob:none --no-checkout https://github.com/llvm/llvm-project.git llvm-project
fi
cd llvm-project
git fetch --filter=blob:none origin "$LLVM_COMMIT"
git checkout --force "$LLVM_COMMIT"
cd ..

# LLVM 16's CMake treats only CMAKE_SYSTEM_NAME == "Darwin" as Apple; iOS has
# its own name, so GNU-only flags (-Wl,-z,defs) and Windows .def export files
# leak into iOS links. Patch the checks to include iOS (idempotent; see README
# "Known issues").
python3 - <<'PY'
import pathlib
base = pathlib.Path("llvm-project/llvm/cmake/modules")
h = base / "HandleLLVMOptions.cmake"
s = h.read_text()
n = s.replace('CMAKE_SYSTEM_NAME MATCHES "Darwin|FreeBSD',
              'CMAKE_SYSTEM_NAME MATCHES "Darwin|iOS|FreeBSD')
if n != s:
    h.write_text(n)
    print("patched HandleLLVMOptions.cmake: iOS skips -Wl,-z,defs")
a = base / "AddLLVM.cmake"
s = a.read_text()
n = s.replace('MATCHES "Darwin")', 'MATCHES "Darwin|iOS")')
if n != s:
    a.write_text(n)
    print("patched AddLLVM.cmake: iOS uses Apple export-list linking")
PY

NPROC="$(sysctl -n hw.ncpu)"

# Host build: only the native tablegen tools the cross build needs.
if [ ! -x llvm-host-build/bin/llvm-tblgen ]; then
  cmake -S llvm-project/llvm -B llvm-host-build -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DLLVM_ENABLE_PROJECTS="" \
    -DLLVM_TARGETS_TO_BUILD="" \
    -DLLVM_BUILD_TOOLS=Off \
    -DLLVM_INCLUDE_TESTS=Off \
    -DLLVM_ENABLE_ZLIB=Off
  cmake --build llvm-host-build --target llvm-tblgen -j "$NPROC"
fi

# iOS build, per the recorded options.
# Note: iOS treats executables as app bundles, so LLVM's install rules for its
# build tools would fail configure. We never install LLVM (DXMT links the
# build-tree libraries), so we skip all install rules.
if [ ! -f llvm-ios-build/CMakeCache.txt ]; then
  cmake -S llvm-project/llvm -B llvm-ios-build -G Ninja \
    -DCMAKE_SYSTEM_NAME=iOS \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_SYSROOT=iphoneos \
    -DCMAKE_BUILD_TYPE=Release \
    -DLLVM_HOST_TRIPLE=arm64-apple-ios17.0 \
    -DLLVM_DEFAULT_TARGET_TRIPLE=arm64-apple-ios17.0 \
    -DLLVM_TARGET_ARCH=host \
    -DLLVM_TARGETS_TO_BUILD="" \
    -DLLVM_ENABLE_PROJECTS="" \
    -DLLVM_BUILD_TOOLS=Off \
    -DLLVM_INCLUDE_TESTS=Off \
    -DLLVM_ENABLE_ZLIB=Off \
    -DLLVM_INSTALL_TOOLCHAIN_ONLY=ON \
    -DLLVM_NO_DEAD_STRIP=ON \
    -DLLVM_ENABLE_PLUGINS=OFF \
    -DLLVM_TABLEGEN="$PWD/llvm-host-build/bin/llvm-tblgen" \
    -DLLVM_NATIVE_TOOL_DIR="$PWD/llvm-host-build/bin"
fi
cmake --build llvm-ios-build -j "$NPROC"
