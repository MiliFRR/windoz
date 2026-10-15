#!/usr/bin/env bash
# Package the built .app into an unsigned IPA (Payload/Madeira.app) ready for
# sideloading.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/madeira"

APP="$(find build/derived/Build/Products -maxdepth 3 -type d -name 'Madeira.app' | head -n 1)"
if [ -z "$APP" ]; then
  echo "ERROR: built Madeira.app not found under build/derived" >&2
  exit 1
fi

STAGE="$ROOT/build/ipa"
rm -rf "$STAGE"
mkdir -p "$STAGE/Payload"
cp -R "$APP" "$STAGE/Payload/Madeira.app"

cd "$STAGE"
ditto -c -k --keepParent Payload "$ROOT/windoz.ipa"
ls -lh "$ROOT/windoz.ipa"
