#!/usr/bin/env bash
# Compile the BASE wineserver archive from wine/server/*.c using Madeira's
# iOS wineserver flags. build/wineserver/build.sh expects
# app/Madeira/libwineserver.a to already contain every server object (it only
# patches/replaces ~28 of them), and no base archive is tracked in the repo —
# so a clean checkout must create one. Per-file failures are reported loudly
# but tolerated, so the archive is as complete as possible; anything missing
# will surface at app link time and get fixed here.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
M="$ROOT/madeira"
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
WINE_SRC="$M/wine"
WS_DIR="$M/build/wineserver"
OBJ_DIR="$ROOT/build/wineserver-base"
OUT="$M/app/Madeira/libwineserver.a"
mkdir -p "$OBJ_DIR"

if [ -f "$OUT" ]; then
  echo "base libwineserver.a already present; keeping it"
  exit 0
fi

CFLAGS=(
  -arch arm64 -isysroot "$SDK" -miphoneos-version-min=17.0 -O2
  -I"$WINE_SRC/include" -I"$WINE_SRC/include/wine"
  -I"$WINE_SRC/build-macos/include"
  -I"$WS_DIR" -I"$WINE_SRC/server"
  -I"$M/build/ntdll-unix/shims"
  -I"$M/build/madsync" -DHAVE_LINUX_NTSYNC_H=1
  -include "$WS_DIR/config_ios.h"
  -include stdarg.h
  -include "$WS_DIR/unicode_fix.h"
  -include "$WS_DIR/wineserver_ios_kill.h"
  -DBINDIR='"/usr/local/bin"' -DDATADIR='"/usr/local/share"'
  -D__WINESRC__ -DWINE_IOS=1
  -Dmain=wineserver_main
  -Wno-implicit-function-declaration
)

SUCCEEDED=0
FAILED=0
FAILED_FILES=""
for src in "$WINE_SRC"/server/*.c; do
  name="$(basename "$src" .c)"
  printf "  %-30s " "$name"
  if xcrun -sdk iphoneos clang "${CFLAGS[@]}" -c "$src" -o "$OBJ_DIR/$name.o" \
      2>"$OBJ_DIR/err-$name.txt"; then
    echo "OK"
    SUCCEEDED=$((SUCCEEDED + 1))
  else
    echo "FAILED (see $(basename "$OBJ_DIR")/err-$name.txt)"
    FAILED=$((FAILED + 1))
    FAILED_FILES="$FAILED_FILES $name"
  fi
done

echo "wineserver base: $SUCCEEDED ok, $FAILED failed${FAILED_FILES}"
if [ "$SUCCEEDED" -eq 0 ]; then
  echo "ERROR: no wineserver objects compiled" >&2
  exit 1
fi

ar rcs "$OBJ_DIR/libwineserver.a" "$OBJ_DIR"/*.o
cp "$OBJ_DIR/libwineserver.a" "$OUT"
echo "base archive: $(wc -c < "$OUT" | tr -d ' ') bytes -> app/Madeira/libwineserver.a"
