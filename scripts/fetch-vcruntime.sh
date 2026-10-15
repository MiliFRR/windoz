#!/usr/bin/env bash
# Supply Microsoft's Visual C++ 2015-2022 x64 runtime DLLs, which Madeira
# never distributes (docs/BUILDING.md, tools/fetch-vcruntime.md). We download
# Microsoft's official vc_redist.x64.exe, unpack it, and keep only the 64-bit
# (PE32+) DLLs the app needs. These are redistributed under Microsoft's own
# terms — they are NOT committed to any repository.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/madeira/app/Madeira/x86_64-vcruntime"
if [ -f "$DEST/.complete" ]; then
  exit 0
fi

WORK="$ROOT/work/vcredist"
rm -rf "$WORK"
mkdir -p "$DEST" "$WORK/unpacked"
cd "$WORK"

curl -fL --retry 3 -o vc_redist.x64.exe "https://aka.ms/vs/17/release/vc_redist.x64.exe"
7zz x -y -ounpacked vc_redist.x64.exe >/dev/null

# The burn bundle contains .cab packages; extract each one.
find unpacked -iname "*.cab" | while read -r cab; do
  outdir="cab-$(basename "$cab")"
  mkdir -p "$outdir"
  7zz x -y -o"$outdir" "$cab" >/dev/null || true
done

COPIED=0
for name in concrt140.dll msvcp140.dll msvcp140_1.dll msvcp140_2.dll msvcp140_3.dll \
            vcamp140.dll vccorlib140.dll vcruntime140.dll vcruntime140_1.dll; do
  hit="$(find . -name "$name" -type f | while read -r f; do
    if file "$f" | grep -q "PE32+"; then
      echo "$f"
      break
    fi
  done | head -n 1)"
  if [ -n "$hit" ]; then
    cp "$hit" "$DEST/"
    COPIED=$((COPIED + 1))
  fi
done

echo "copied $COPIED VC++ runtime DLLs into app/Madeira/x86_64-vcruntime"
if [ "$COPIED" -lt 5 ]; then
  echo "ERROR: too few VC++ runtime DLLs found; check the extraction layout" >&2
  exit 1
fi
touch "$DEST/.complete"
