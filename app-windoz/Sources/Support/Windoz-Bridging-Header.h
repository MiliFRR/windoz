#ifndef WINDOZ_BRIDGING_H
#define WINDOZ_BRIDGING_H

// Windoz — engine binding layer. The C/ObjC glue below drives the engine
// forks (Wine ARM64EC, FEX-Emu, wineserver-in-a-thread). GPL-3.0, derived
// from the interface those forks require (see Engine/README.md).

#import "../../../madeira/app/Madeira/WineProcessBridge.h"
#import "../../../madeira/app/Madeira/FEXBridge.h"
#import "../../../madeira/app/Madeira/WineServerBridge.h"
#import "../../../madeira/app/Madeira/JITAllocator.h"
#import "../../../madeira/app/Madeira/PrefixExtractor.h"
#import "../../../madeira/app/Madeira/IOSDisplayShim.h"
#import "../../../madeira/app/Madeira/Winios/Winios.h"
#import "../../../madeira/app/Madeira/PadOutput.h"
#import "JITProbe.h"

// The presented-frame counter exported by DXMT's unix side (the pinned engine
// trees declare it the same way). The session overlay reads it to tell
// "waiting for the first frame" from "rendering", so the status line never
// claims a game is drawing before it has.
#include <stdint.h>
uint64_t madeira_get_present_count(void);

// The Steam depot downloader's C helpers (chunked-zip framing, an LZMA
// decoder shim and an educational zstd decoder), ported with the SwiftSteam
// client from Madeira (GPL-3.0-or-later + Madeira Converter Exception).
#import "../Steam/chunk_zip.h"
#import "../Steam/lzma_shim.h"
#import "../Steam/zstd_edu.h"

#endif
