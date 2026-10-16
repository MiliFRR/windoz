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

#endif
