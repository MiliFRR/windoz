#!/usr/bin/env bash
# Supply Microsoft's Visual C++ 2015-2022 x64 runtime DLLs, which Madeira
# never distributes (docs/BUILDING.md, tools/fetch-vcruntime.md).
#
# Source: the "vc-runtime-inputs" release asset on this repository — the DLLs
# were copied from C:\Windows\System32 of the owner's licensed Windows
# install (CRT 14.44). Redistribution is permitted under Microsoft's Visual
# Studio Redistributable terms; the DLLs are NOT part of the GPL source tree.
# The zip is hash-pinned here so the build stops on any substitution.
#
# NOTE: 7-Zip can no longer extract Microsoft's 2022 vc_redist.x64.exe burn
# container (WiX 4 format), which is why the pre-extracted asset is used.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/madeira/app/Madeira/x86_64-vcruntime"
if [ -f "$DEST/.complete" ]; then
  exit 0
fi

ZIP_SHA256="d19d19533aebe4632eff325e40443a3c908904376e0d7c03165be54865530e1a"
URL="https://github.com/MiliFRR/windoz/releases/download/vc-runtime-inputs/x64-vcruntime.zip"

WORK="$ROOT/work/vcredist"
rm -rf "$WORK"
mkdir -p "$DEST" "$WORK"
cd "$WORK"

curl -fL --retry 3 -o x64-vcruntime.zip "$URL"
echo "${ZIP_SHA256}  x64-vcruntime.zip" | shasum -a 256 -c -

unzip -q x64-vcruntime.zip -d dlls
cp dlls/*.dll "$DEST/"

cat > "$DEST/PROVENANCE.txt" <<'EOF'
Microsoft Visual C++ 2015-2022 x64 runtime DLLs (CRT 14.44).
Source: copied from C:\Windows\System32 of the windoz owner's licensed
Windows install; distributed from the repository's "vc-runtime-inputs"
release. Redistribution permitted under Microsoft's Visual Studio
Redistributable terms (https://visualstudio.microsoft.com/license-terms/).
These DLLs are not covered by the GPL of the surrounding project.
EOF

echo "VC++ x64 runtime staged into app/Madeira/x86_64-vcruntime:"
ls -la "$DEST"/*.dll
touch "$DEST/.complete"
