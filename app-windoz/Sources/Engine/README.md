# The Windoz engine boundary

Everything in this folder is the **only** place in Windoz that knows the
emulation engine exists. `WindozEngine.swift` is the public face; the rest of
the app (UI, stores, downloads, settings) uses it and the plain Swift value
types in `EngineTypes.swift` — never a Wine, FEX or DXMT symbol.

## What is underneath

| File | Role |
|---|---|
| `WindozEngine.swift` | the boundary: health, prefix, engine core, session launch/poll/end, stop |
| `EngineTypes.swift` | `EngineStatus`, `EngineHealth`, `SessionPhase`, `SessionOutcome`, `GameSettings`, `InstalledGame`, `EngineError` |
| `PrefixManager.swift` | the Wine prefix at the negotiated storage root (`AppContainer.prefixRoot` — `Documents/windoz-prefix` whenever Documents accepts writes, migrated as one unit otherwise), plus host ↔ guest path mapping |
| `AppContainer.swift` | every storage decision: the write-probe table, the storage root, the prefix home, art and library paths |
| `ContainerFS.swift` | the C-library route (`creat`/`write`/`unlink`, BSD flags, mode bits) every write decision checks against Foundation |
| `GameLibrary.swift` | the installed games, their settings and playtime |
| `JITManager.swift` | JIT probing, the StikDebug deep link, memory and signing facts |
| `RuntimeDependencies.swift` | which Microsoft runtimes a game may need, and honest staging |
| `AppEnvironment.swift` | LiveContainer / Simulator / sideload detection |
| `EngineLogStream.swift` | the in-app log, fed by the engine's C callbacks |

Below that boundary are two things:

1. **C/ObjC glue from the pinned `madeira` submodule** — `WineProcessBridge`,
   `WineServerBridge`, `FEXBridge`, `JITAllocator`, `PrefixExtractor`,
   `IOSDisplayShim`, `Winios`, `PadOutput` — listed in `app-windoz/project.yml`
   and reached through `Sources/Support/Windoz-Bridging-Header.h`. These are
   GPL-3.0-or-later with the Madeira Converter Exception (see `LICENSE` and
   `LICENSE-EXCEPTION.md` at the repository root). Windoz compiles them
   unmodified, straight out of the submodule.
2. **The engine forks themselves** — the Wine ARM64EC fork, FEX-Emu, DXMT and
   the native D3D12 runtime — built as static libraries by
   `scripts/build-runtime.sh` and linked with the app. They are the work of
   their own authors; Windoz reuses them.

`Sources/Support/JITProbe.c` and `Sources/Support/WiniosShims.c` are Windoz's
own original code (a JIT page probe and a thread-stack dumper), not taken from
any other app.

## The honesty contract

Every method here either does what it says or throws an `EngineError` naming the
missing piece. `launch` runs a real preflight (JIT, prefix, executable, guest
environment), waits for the session screen's presenting layer, and then starts
the engine core and the guest process; the session ends on the guest process's
own exit, and every failure names the exact step. The honest limits — one
session per app run, single-touch plus hardware-keyboard input, graphics
switches that are stored but not applied — are in `docs/ENGINE.md`, which lists
what is wired and what is not, with sources; `docs/ROADMAP.md` keeps the same
status for the whole app.
