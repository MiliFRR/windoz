#!/usr/bin/env bash
# Package the built .app into an unsigned IPA (Payload/Windoz.app) ready for
# sideloading. The new original app (app-windoz/, XcodeGen project) produces
# Windoz.app; the old madeira app produced Madeira.app — support both so the
# pipeline can build either.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/madeira"

APP="$(find build/derived/Build/Products -maxdepth 3 -type d -name 'Windoz.app' -o -maxdepth 3 -type d -name 'Madeira.app' | head -n 1)"
if [ -z "$APP" ]; then
  echo "ERROR: built Windoz.app/Madeira.app not found under build/derived" >&2
  exit 1
fi
APP_NAME="$(basename "$APP")"

STAGE="$ROOT/build/ipa"
rm -rf "$STAGE"
mkdir -p "$STAGE/Payload"
cp -R "$APP" "$STAGE/Payload/$APP_NAME"

cd "$STAGE"
ditto -c -k --keepParent Payload "$ROOT/windoz.ipa"
ls -lh "$ROOT/windoz.ipa"
