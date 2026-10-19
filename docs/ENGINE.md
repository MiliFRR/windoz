# Windoz engine boundary

This document describes the single interface between Windoz's own code and the
Windows-emulation engine, what is genuinely wired today, and how Direct3D 12 is
handled. It exists so the honesty contract in the code is checkable: *nothing
above the boundary may claim a capability the engine does not actually have.*

## 1. The boundary

`app-windoz/Sources/Engine/WindozEngine.swift` is the only file in the app that
references engine symbols. Everything else (UI, stores, downloads, settings)
talks to `WindozEngine` and to plain Swift value types (`InstalledGame`,
`GameSettings`, `EngineStatus`, `EngineHealth`, `EngineError`).

```
UI / stores / downloads
        │  plain Swift types only
        ▼
WindozEngine            (Engine/WindozEngine.swift)
        │  C/ObjC symbols, one place
        ▼
Windoz-Bridging-Header.h + Support/*.c
        │
        ▼
madeira  ── pinned git submodule ───────────────────────────────┐
   Wine (ARM64EC fork)   FEX-Emu   DXMT   native D3D12 runtime  │
   app/Madeira/{WineProcessBridge,WineServerBridge,FEXBridge,    │
                JITAllocator,PrefixExtractor,IOSDisplayShim,     │
                Winios,PadOutput}.*                              │
   arm64ec-windows/  (PE DLL farm)   prefix-template.tar.gz      │
   d3d12/ + arm64ec-windows/madeira_d3d12.dll                    │
                                                                ┘
```

The engine components are **reused** from the pinned `madeira` submodule
(commit pinned in `.gitmodules` / the gitlink). Windoz's own app code — UI,
stores, downloads, settings — is written from scratch. The ObjC/C files listed
in `app-windoz/project.yml` are the binding layer those forks require; they are
GPL-3.0-or-later with the Madeira Converter Exception and are attributed in
`README.md` and the in-app Licenses screen.

## 2. What is actually implemented

| Capability | State | Entry point |
|---|---|---|
| Prefix create / repair / delete | **working** | `PrefixManager` → `madeira_seed_prefix_if_needed` |
| Wine service process (wineserver as a thread) | **working** | `wineserver_start`, `wineserver_is_ready`, `wineserver_stop` |
| Executable-memory (JIT) pool for the guest | **ported from Madeira in 0.7.0 — device-verification pending** | `JITPool.ensure` → `jit26_prepare_region` (debugger BRK), RW alias via `vm_remap`, then `WINE_IOS_JIT_RX/RW/SIZE` |
| In-process FEX init / shutdown | **not on the launch path** | Madeira's engine never initialises the app-side FEX bridge for a game; the Wine fork's own translator uses the pool above. The bridge remains only for its self-test. |
| Engine logs (FEX + JIT) into the in-app log | **working** | `fex_set_log_callback`, `jit_set_log_callback` |
| JIT readiness probe | **working** | `windoz_jit_probe` (own code): sticky `CS_DEBUGGED` **and** a live debugger (`P_TRACED`) — maps and executes nothing |
| Increased-memory entitlement report | **working** | `task_info(TASK_VM_INFO)` + `jit_available_memory` |
| Windows runtime detection / official download | **working** | `RuntimeInstaller` (files + `DownloadManager`) |
| Game **session host** (Metal presentation + input + the guest process) | **ported in 0.3.4 — device verification pending** | `WindozEngine.launch` → `wine_process_start`; the presenting layer and overlay live in `Sources/UI/GameSessionView.swift` |
| Per-game **launch modes** (Direct / Doz Dock / Steam desktop) | **ported in 0.4.0 — device verification pending** | `WindozEngine.prepareLaunchMode` + `Sources/Steam/Content/DozDock.swift` |
| Session **gamepad** (on-screen pad + a physical controller → XInput slot 0) | **0.8.0 — device verification pending** | `SessionGamepad` → `winios_gamepad_set_state` (WiniosGamepad.h) |
| **Swap tier** (the engine's file-backed guest memory) | **0.8.0 — device verification pending** | `MadeiraConfig` writes `Documents/madeira.cfg`; armed by `wine_process_start` |
| **Storage negotiation** (the root that accepts writes) | **working (0.4.0)** | `AppContainer.probeWrites` / `storageRoot`; the prefix follows it (`PrefixManager`) |
| Native store clients | **Steam: sign-in + owned library device-verified, depot downloads device-verification pending; Epic: both sign-ins device-verified, chunked downloads in 0.4.0 — the instant-failure root cause (chunk URLs had carried the manifest's signed query string) fixed in 0.5.0, off-device tests in `tests/host` (device verification pending)** | `SteamStore`, `EpicStore`, `EpicDownloader` |

`WindozEngine.launch` performs a **real** preflight — JIT re-checked, the
prefix created at the negotiated storage root, the storage gate proving that
root itself accepts writes, the executable stat'd, the launch mode prepared
(`prepareLaunchMode`: Direct needs only the program; Doz Dock validates and
writes the handoff; Steam desktop checks the client components) — then hands
the game to the session screen, which registers the presenting `CAMetalLayer`
with the engine's display shim (`madeira_display_set_layer`, once per process,
before the guest's first swapchain). The guest then starts through **Madeira's
own sequence**, on the engine queue: the attached debugger grants the JIT pool
(`jit26_prepare_region`) and the pool's three `WINE_IOS_JIT_*` variables are
published → the debugger is detached (Madeira's early detach; every executable
page comes from the pool) → `wineserver_start` if the service is not already up
→ `wine_exit_status_reset` → `wine_process_start`. There is **no app-side
`fex_initialize`** on this path. The session ends when the guest process does;
the engine's own exit report (`wine_crash_exit_status`) decides the message, and
a session that never starts is closed with an honest note by the 160-second
stall budget.

The honest limits of this first session host:

- **One session per app run.** Wine's service process (a thread in this app)
  keeps the first session's registry state, so after a session ends the UI asks
  for an app restart instead of pretending a second session works.
- **Input** is a single primary touch mapped 1:1 onto the guest's virtual
  monitor (aspect-fit), a hardware keyboard when one is attached (UIKey →
  virtual-key, US layout), and a small on-screen key row (arrows, Esc, Tab,
  Enter, Space) — enough to play a platformer with touch as the mouse. 0.8.0
  adds controllers, chosen per game and switchable from the session's ⚙ menu:
  **Keyboard & mouse** (default) translates a physical pad to WASD + mouse +
  the template keys and never tells the game a controller exists; **Xbox** and
  **PlayStation 5** merge a physical controller and the on-screen pad into one
  XInput snapshot (dead zone 7849, the engine's own value) published to slot 0
  with `winios_gamepad_set_state` — the PS5 layout is the same Xbox-style pad
  with DualSense glyphs, stated plainly. No software keyboard yet.
- **Leaving a session** asks the game to close with Alt+F4; "leave the session
  screen" detaches and says plainly that a still-running guest ends with the
  app. Nothing here ever calls `wineserver_stop()` while a guest thread exists
  — that thread owns the call, and joining the service thread twice is not
  safe.
- `GameSettings` says which of its fields are applied and which are only
  stored, in the settings sheet and in the launch log. Applied per launch: the
  frame pacing (the engine's own `madeira_set_vsync_locked` call — see §3a)
  and the per-game variables in the table below. Stored only, and labeled as
  such: the present/queue mode, MetalFX upscaling and the D3D11/D3D12 backend
  choice — this build has no engine switch or call for them.

## 3. Launch environment

`WindozEngine.applyLaunchEnvironment` writes **only** the switch names the
pinned forks actually read. Sources are the fork/app files named below.

| Variable | Meaning | Written when | Source |
|---|---|---|---|
| `MADEIRA_EXE` | program to run: a `C:\…` path in the prefix, or `Z:\…` for a game outside it | always | `WineProcessBridge.m` (path resolution), `Library.swift configureLaunch` |
| `MADEIRA_ARGS` | space-separated extra argv (≤ 16 tokens) | when non-empty | `WineProcessBridge.m` |
| `MADEIRA_SCREEN_W` / `MADEIRA_SCREEN_H` | the virtual monitor's session default size | always | `GuestDisplay.configureSessionDefault`, `win32u-unix/sysparams_ios.c` |
| `MADEIRA_SCREEN_SRC` | where that default came from (log line only) | always | `sysparams_ios.c` |
| `MADEIRA_WORKDIR` | the working folder, **only** a `C:\` folder | when configured | `WineProcessBridge.m` (guarded chdir) |
| `MADEIRA_DESKTOP` | run the Wine desktop (`explorer.exe`) | reserved | `Library.swift configureLaunch` |
| `MADEIRA_STEAM_APPID` / `MADEIRA_STEAM_APPPATH` | a Steam game's own App ID / install folder | Direct mode, when the title has an identity Windoz can prove (digits ≤ 10; a `C:\` folder with no `..`); **unset otherwise**, so the engine's built-in fallback cannot leak another game's identity | `WineProcessBridge.m` |
| `MADEIRA_DOCK_SESSION`, `MADEIRA_DOCK_AUTH_FILE`, `MADEIRA_DOCK_OFFLINE`, `MADEIRA_STEAM_HOST_APPID`/`_LAUNCH_OPTION`/`_CLIENT_DIR`/`_EXPECTED_INSTALL`/`_LOG`/`_CEG` | Doz Dock / Steam desktop — see "Launch modes" below; written only for those modes and unset after every session | per launch, mode-dependent | `DozDock.swift` (mirrors the pinned `MadeiraDock.swift`) |
| `MADEIRA_FASTSYNC` | Wine's sync engine — `auto`, `1`, `cells`, `0` | when the game's Sync engine choice is not "Engine default" | `WineProcessBridge.m` (per-launch list), `Library.swift applyEnvironment` |
| `FEX_X87REDUCEDPRECISION`, `MADEIRA_FEX_AVX`, `MADEIRA_CPU_COUNT`, `MADEIRA_DINPUT_PAD`, `DXMT_D9_ANISO_LIMIT`, `MADEIRA_GAME_WINDOWS`, `MADEIRA_WAIT_CHILDREN`, `MADEIRA_VIRTUAL_MODE_SET` | the per-game engine switches in the settings sheet — each is set *or* unset on every launch, so a previous game's choice never leaks into the next | when the game sets them | `WineProcessBridge.m` (per-launch list), `Library.swift applyEnvironment` |
| `FEX_X87REDUCEDPRECISION`, `MADEIRA_CPU_COUNT`, `DXMT_D9_ANISO_LIMIT`, … | the user's own fork switches (applied last, so an expert entry can override the sheet) | from `GameSettings.environment` | `Library.swift applyEnvironment` |

### Swap memory (0.8.0)

The pinned engine has a file-backed guest memory tier; the app does not
allocate it. `MadeiraConfig` owns exactly two keys in **`Documents/madeira.cfg`**
— the same file and keys Madeira's Memory page writes — and everything else in
the file is preserved byte-for-byte (atomic write, read-back verified):

| Key | Meaning |
|---|---|
| `swap-mb` | tier size in MB; **Off** removes the key. `wine_process_start` arms the tier only at ≥ 64 MB: it recreates `NSTemporaryDirectory()/madeira-swap.bin` (`NSFileProtectionNone`) and exports `MADEIRA_SWAP_FILE` / `MADEIRA_SWAP_MB` to the guest |
| `env.MADEIRA_SWAP_COVERAGE` | which allocations draw on the tier — `classic` (the engine's default: omitted), `blocks`, `wide`, `broad` |

The bridge reads the file when the session starts, so a change takes effect on
the **next launch**; the launch log states the tier it found (on with size and
coverage, or off). If removing the keys leaves no meaningful line, the file is
deleted rather than left empty (an empty cfg would still switch the engine from
legacy per-key files to cfg parsing).

### Launch modes (0.4.0)

`GameSettings.launchMode` picks how a title starts; `prepareLaunchMode`
validates it before anything is written, and the launch log names the mode:

- **`direct`** — the game's own program (everything before 0.4.0). For a
  Steam title, the engine's own identity variables are published per the
  table above — and *unset* when the title has none.
- **`dock`** — **Doz Dock**: Valve's own client, through the dock host ported
  from Madeira. `DozDock.writeHandoff` writes the launch file (envelope
  `MDOCK001` + Steam ID + App ID + name + token, `0600`,
  `O_CREAT|O_EXCL|O_NOFOLLOW`, App Support first with the storage root as
  fallback); `DozDock.configure` sets `MADEIRA_STEAM_HOST_APPID`,
  `_LAUNCH_OPTION=0`, `_CLIENT_DIR=C:\Program Files (x86)\Steam`,
  `_EXPECTED_INSTALL=<the game's Windows install path>`,
  `_LOG=C:\madeira-dock.txt` and `_CEG=1` for CEG titles; the session writes
  `MADEIRA_DOCK_SESSION=1` and points `MADEIRA_DOCK_AUTH_FILE` at the
  handoff. After the session, the host's report
  (`<prefix>/drive_c/madeira-dock.txt`) is parsed against an allow-list,
  translated to plain words, and deleted along with the handoff and every
  dock variable.
- **`steamDesktop`** — the same client components, no game auto-started: the
  full Steam client in a virtual desktop for manual sign-in and library use.

**Offline** is Valve's own offline mode: `MADEIRA_DOCK_OFFLINE=1` is set only
when the per-game toggle is on or `NWPathMonitor` reports no network — never
faked, never emulated. Both dock modes refuse with a sentence
(`EngineError.dockNotReady` / `.steamDesktopNotReady`) when something is
missing: the bundled `dockhost.exe`, a readable Steam sign-in, the client
components, or the game's own `appmanifest_<appid>.acf` inside the **active**
prefix's `steamapps`. The components themselves install from Valve's pinned
CDN packages (`SteamClientRuntime`: sizes + SHA-256 checked, Steam's registry
keys and redirects written); "prepared" means `steam.exe` and
`steamclient64.dll` exist — checked, not assumed.



`GameSettings.fpsLimit` is applied through the engine's own in-process call
`madeira_set_vsync_locked`, at session start and again when the guest's first
frame is seen — the same call, with the same values, the pinned front end's
FPS menu makes (`1` = 60, `3` = 30, `4` = 40, `0` = display maximum,
`2` = uncapped). The symbol is resolved with `dlsym` at first use; if a build
does not export it, the launch log says so and the choice stays stored — the
call is never faked.

Settings that have **no** environment variable are deliberately *not* faked:

| `GameSettings` field | How the engine applies it | Why no env var |
|---|---|---|
| `syncMode` (present/queue) | presentation/queue policy in the app's session host | no engine switch exists — stored, not applied yet |
| `graphicsBackend` (D3D11/D3D12) | which `d3d12.dll` implementation the loader resolves | there is no per-game switch in the forks (see §4); `auto` is what actually runs |
| `metalFXUpscaling` | MetalFX spatial scaler created by the session host | no env switch; not created yet — stored, not applied |

The log records these decisions for a session ("stored, not applied — no
engine switch for them in this build") so the UI can explain them without
inventing a switch.

### Path mapping

`InstalledGame.executablePath` is a host path inside the app container.
`PrefixManager.windowsPath(forHostPath:)` turns a path under
`<storage root>/windoz-prefix/drive_c` into its `C:\…` guest path. The
storage root itself is negotiated since 0.4.0 (`AppContainer.probeWrites`: a
real create + replace + delete per candidate, through Foundation *and* the C
library; the first pass wins and is remembered in `windoz-storage.json`) —
on the owner's device `Documents` refuses every write at policy level, so the
environment relocates instead of failing. A game installed outside the
prefix is exposed through Wine's default `Z:` root mapping
(`Z:\private\var\…`). `MADEIRA_WORKDIR` is only written for a `C:\` folder,
because the engine chdir's into it and rejects anything else.

## 4. Direct3D 11 and Direct3D 12

**D3D11 → DXMT.** A game's `d3d11.dll` calls resolve to DXMT, which forwards to
Metal through `winemetal.dll`: `d3d11.dll → winemetal.dll → Metal`. This is the
working, shipped path.

**D3D12.** Two objects exist in the prefix:

- Wine's bundled **`d3d12.dll`** is the normal loader entry point.
- `arm64ec-windows/madeira_d3d12.dll` (machine `IMAGE_FILE_MACHINE_ARM64EC`) is
  Madeira's **separate native D3D12 core**, exporting `MadeiraD3D12CreateDevice`
  and `MadeiraD3D12GetBuildMarker`. It is *not* a drop-in replacement for the
  bundled loader; Madeira reaches it through dedicated test programs
  (`d3d12-m2-x64.exe`, `d3d12-cube-x64.exe`, `d3d12-vfetch-x64.exe`).

The native core drives Metal through the **same winemetal bridge** D3D11 uses,
so it inherits the existing local/remote transport. Application **DXIL is
converted to Metal at pipeline creation** (winemetal call 127) against the root
signature the application actually created, using Apple's **Metal Shader
Converter** (`d3d12/libmetalirconverter.dylib`, loaded under the app's own
signing arrangement, Apple-branded hardware only). There is no embedded shader
fixture: `madeira_d3d12.dll` contains no precompiled `MTLB` payload.

What this means for Windoz:

- `GraphicsBackend.auto` is the honest default: let the game load its own
  `d3d12.dll`. `GraphicsBackend.d3d11` / `.d3d12` are stored and reported, but
  **this build's session host does not apply the choice** — `auto` is what
  actually runs — and Windoz does **not** invent a `MADEIRA_D3D12` environment
  variable (the forks do not read one). The documented D3D12 *env* switches
  that do exist are diagnostics only — `MADEIRA_D3D12_DXIL_CACHE`,
  `MADEIRA_D3D12_DXIL_CACHE_MB`, `MADEIRA_D3D12_ONEPASS` — and pass through
  `GameSettings.environment` if the user sets them.
- Native D3D12 coverage is **experimental** (M1–M5 milestone results are
  recorded in `madeira/madeira-d3d12/README.md`). Reporting it as "working for
  every game" would not be honest, so the game page presents it as an option
  with that caveat.

## 5. JIT and memory

On a jailed device, executable memory a *generated* process writes is only
allowed while a debugger has attached and set `CS_DEBUGGED`. Windoz supports two
routes:

- **StikDebug** (the separate app): `JITManager.stikDebugEnableURL()` builds a
  `stikdebug://enable-jit?bundle-id=…&pid=…&script-data=…` URL, where the script
  is the engine's `madeira-jit.js` (bundled as a resource), base64-encoded. This
  is the only route inside **LiveContainer**: `LC_HOME_PATH` is set there, the
  guest app runs in LiveContainer's process, and a bundled app extension cannot
  be started, so `JITManager.builtInHelperUsable` is false.
- **Bundled helper extension** on a normal sideload — *not in this build*. The
  helper target does not exist yet, so `JITManager.builtInHelperUsable` reads
  the bundle (`Bundle.main.builtInPlugInsURL`) and reports false, and
  `AppEnvironment.availableJITMethods` therefore offers only StikDebug. The
  moment the extension is added to the bundle the choice appears by itself;
  until then nothing claims it is there.

`WindozEngine.refreshStatus` probes JIT, memory and storage off the main thread;
`launch` re-checks JIT on **every** launch. The increased-memory entitlement
cannot be added at run time and is reported honestly as unavailable when the
signing profile lacks it (LiveContainer re-signs without it).

## 6. Licensing

Windoz is **GPL-3.0-or-later with the Madeira Converter Exception**. The
licence texts and third-party notices are bundled as resources and shown in
Settings → Licenses. Microsoft Windows runtime files are **never**
redistributed: they are downloaded on-device from Microsoft's own servers, or
staged from the prefix template the engine ships. Apple's Metal Shader Converter
dylib is used under Apple's agreement (section 2.B) and only on Apple hardware.
