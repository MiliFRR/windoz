#!/usr/bin/env bash
# Build the iOS app itself. Debug configuration is the one that runs games
# (Madeira docs/BUILDING.md: Release builds have crashed the guest). The
# build is left unsigned; the sideloading tool (SideStore / AltStore /
# Sideloadly) signs it with the user's Apple ID at install time.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/madeira"

# --- windoz UI overrides: our repo's overrides/ tree replaces submodule
# files at build time (no Xcode project surgery needed — same filenames,
# same build phases). Currently: the windoz console home screen.
if [ -d "$ROOT/overrides/app/Madeira" ]; then
  cp -f "$ROOT"/overrides/app/Madeira/*.swift app/Madeira/
  echo "windoz UI overrides applied: $(ls "$ROOT"/overrides/app/Madeira/*.swift | wc -l | tr -d ' ') file(s)"
fi

# --- windoz branding: display name (the bundle id is set via the xcconfig)
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName windoz" app/Madeira/Info.plist 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string windoz" app/Madeira/Info.plist

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
