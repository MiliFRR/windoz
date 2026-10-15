#!/usr/bin/env bash
# Build the iOS app itself. Debug configuration is the one that runs games
# (Madeira docs/BUILDING.md: Release builds have crashed the guest). The
# build is left unsigned; the sideloading tool (SideStore / AltStore /
# Sideloadly) signs it with the user's Apple ID at install time.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/madeira"

xcodebuild \
  -project app/Madeira.xcodeproj \
  -scheme Madeira \
  -configuration Debug \
  -destination 'generic/platform=iOS' \
  -allowProvisioningUpdates \
  -xcconfig "$ROOT/overlay/windoz.xcconfig" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  -derivedDataPath build/derived \
  build
