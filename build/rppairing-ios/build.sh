#!/bin/bash
# Build libwindoz_rppairing.a (on-device remote pairing for Built-in JIT,
# app-windoz/Sources/Engine/OnDevicePairing.swift) for iOS arm64 and copy it to
# app-windoz/libs, where the app target links it. The C interface is
# app-windoz/Sources/Support/WindozRPPairing.h.
#
# Ported from Madeira's build/rppairing-ios/build.sh (GPL-3.0-or-later, Madeira
# Converter Exception). Dependencies come from crates.io at the versions in
# Cargo.lock (idevice is MIT, jkcoxson/idevice). Their licence notices are
# regenerated into app-windoz/Resources/Legal/LICENSES-rppairing-crates.txt,
# which the app bundles. Needs rustup with the aarch64-apple-ios target
# (`rustup target add aarch64-apple-ios`) and python3.
set -euo pipefail

BUILD_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$BUILD_DIR/../.." && pwd)"
TARGET=aarch64-apple-ios
export IPHONEOS_DEPLOYMENT_TARGET=17.0

cd "$BUILD_DIR"
cargo build --release --locked --target "$TARGET"
mkdir -p "$REPO_ROOT/app-windoz/libs" "$REPO_ROOT/app-windoz/Resources/Legal"
cp "target/$TARGET/release/libwindoz_rppairing.a" "$REPO_ROOT/app-windoz/libs/libwindoz_rppairing.a"
echo "-> app-windoz/libs/libwindoz_rppairing.a"
python3 "$BUILD_DIR/notices.py" "$REPO_ROOT/app-windoz/Resources/Legal/LICENSES-rppairing-crates.txt"
echo "-> app-windoz/Resources/Legal/LICENSES-rppairing-crates.txt"
