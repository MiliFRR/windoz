#!/usr/bin/env bash
# Fetch the pinned llvm-mingw toolchain (ARM64EC PE cross compiler) used for
# the Windows-side builds. Pinned to the exact release Madeira records in
# docs/BUILDING.md, verified by SHA-256.
set -euo pipefail

VER="20260421"
SHA="bd85a3975723815cef28dbbd2ca2cb0c926f6b348a12a0453f39f7af273cb3f7"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/madeira/toolchains"

DIR="llvm-mingw-${VER}-ucrt-macos-universal"
if [ ! -d "$DIR" ]; then
  curl -fL --retry 3 -o "${DIR}.tar.xz" \
    "https://github.com/mstorsjo/llvm-mingw/releases/download/${VER}/${DIR}.tar.xz"
  echo "${SHA}  ${DIR}.tar.xz" | shasum -a 256 -c -
  tar -xJf "${DIR}.tar.xz"
  rm -f "${DIR}.tar.xz"
fi
