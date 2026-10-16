#!/usr/bin/env bash
# Build the ORIGINAL Windoz app (app-windoz/). The engine chain
# (build-runtime.sh etc.) must have run first — this script generates the
# Xcode project from project.yml (XcodeGen) and builds it.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/app-windoz"

brew list xcodegen >/dev/null 2>&1 || brew install xcodegen
xcodegen generate

xcodebuild -project Windoz.xcodeproj -scheme Windoz -configuration Debug \
  -destination 'generic/platform=iOS' -allowProvisioningUpdates \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
  -derivedDataPath build/derived build
