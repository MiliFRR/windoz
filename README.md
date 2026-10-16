# windoz

A Windows game launcher and runner for iPhone. Sign in to Steam, browse your
library in a console-style UI, download games in the background, and run them
locally — unmodified — on a jailed iPhone (iOS 26+, sideloaded only).

**Status: Phase 0 ✅ COMPLETE — CI run #24 produced the first
`windoz.ipa` (145 MB).** Phase 1 (runtime test on device) is next.

## app-windoz — the current app

The app now lives in `app-windoz/`, an [XcodeGen](https://github.com/yonaskolb/XcodeGen)
project whose Swift sources (UI, stores, downloads, settings) are written from
scratch. The engine — Wine ARM64EC, FEX-Emu, DXMT and the native D3D12 core —
is reused from the pinned `madeira` submodule behind one boundary,
`WindozEngine`. The UI never talks to Wine directly.

- [`docs/ENGINE.md`](docs/ENGINE.md) — the boundary, the launch environment, and
  how Direct3D 11 (DXMT) and Direct3D 12 (native) are handled.
- [`docs/ROADMAP.md`](docs/ROADMAP.md) — honest, item-by-item status
  (✅ done / 🟡 partial / ⛔ not implemented). A feature is only ✅ when it was
  observed working, on a device where device behaviour matters.

The engine core (wineserver + FEX), prefixes, JIT probing, runtime detection and
downloads are real and testable today. **Hosting a full game session (rendering +
input) is the remaining engine port**; until it lands, Play runs a real preflight
and then reports that honestly instead of pretending to play.

## Decisions (recorded 2026-10-15)

| Question | Decision |
|---|---|
| Device | iPhone 17 (A19, 8 GB RAM); deployment target iOS 26, arm64 — every newer iPhone works too |
| Build | GitHub Actions on `MiliFRR/windoz` (macOS runners); no Mac needed |
| Steam DRM games | In scope — Madeira's Dock approach ported and improved as **Doz Dock** (Phase 5) |
| Test game (Phase 1) | BROTHER!!! Save him! – Hardcore Platformer (Steam AppID 1286560; 64-bit, 300 MB, gamepad support). DRM caveat: if its `steam_api` requires the Steam client, it launches via Doz Dock, not directly |
| Apple ID | Free (7-day re-sign via SideStore/AltStore) |

## Credit and licence

windoz builds on [**Madeira**](https://github.com/willfaust/Madeira) by Will
Faust (GPL-3.0-or-later with the Madeira Converter Exception), which runs
x86-64 Windows games on iOS via Wine (ARM64EC) + FEX-Emu + DXMT in a single
process. Steam sign-in, the owned-library client and the depot downloader
derive from Jfishin's SwiftSteam (via Madeira, GPL-3.0-or-later + exception).

**windoz is GPL-3.0-or-later with the same Converter Exception** (see
`LICENSE` and `LICENSE-EXCEPTION.md`). The source is public; anything shared
as an IPA must come from this public source. New windoz code (UI, Live
Activity, settings, tooling) is ours; components we cannot recreate
(Wine/FEX/DXMT forks, depot downloader, dock) are **used** from Madeira as a
pinned submodule.

## Phase 0 design — this repository

A thin repo: our own scripts + CI + overlay, with Madeira pinned as the
`madeira` submodule (commit `279fd0f8`, whose FEX/wine/dxmt/dock submodules
are public as of 2026-10-14). The pipeline:

1. `scripts/build-llvm.sh` — builds LLVM for iOS per Madeira's recorded
   CMakeCache options (host tablegen build + iOS cross build). Cached across
   runs keyed on the LLVM commit.
2. `scripts/fetch-llvm-mingw.sh` — pinned llvm-mingw `20260421` release,
   SHA-256 verified.
3. `scripts/fetch-vcruntime.sh` — extracts Microsoft's VC++ x64 runtime from
   the official `vc_redist.x64.exe` (PE32+ DLLs only; never committed).
4. `scripts/build-runtime.sh` — the full native chain in Madeira's prescribed
   order: GnuTLS → FFmpeg → FEX (unix + ARM64EC) → Wine (unix + ARM64EC PE)
   → DXMT (unix + PE) → Wine Mono → in-app pairing → native D3D12 → stubs →
   faultrep → Madeira Dock (non-fatal in Phase 0).
5. `scripts/build-app.sh` — Xcode **Debug** build (the configuration that
   runs games), unsigned, with `overlay/windoz.xcconfig` giving the app its
   own bundle id (`com.milifrr.windoz`; the JIT helper follows it).
6. `scripts/assemble-ipa.sh` — packages `Payload/Madeira.app` into
   `windoz.ipa`, uploaded as a CI artifact.

## Phases

- [x] **Phase 0 — Reproducible build.** CI produces an installable IPA from a
  clean clone (runs #1–#24; ten issues found and fixed — full ledger in
  Known issues below). The LLVM cache is saved across runs, so future builds
  skip the ~25 min LLVM compile. **First IPA: run #24.**
- [ ] **Phase 1 — Runtime.** Launch a simple 64-bit game from a local
  folder; Settings shows JIT + Memory+ status; launch blocked with a clear
  message when not ready.
- [ ] **Phase 2 — UI shell.** Console-style Library with mock data: cover-art
  carousel, focus/selection animation, ambient blur, dark theme.
  **In progress — Phase 2 step 1 shipped:** the app now roots into a windoz
  console home (dark theme, cover carousel with focus animation, "OPEN
  CONSOLE" entry into the full engine/library). Delivered as a build-time
  override (`overrides/app/Madeira/MadeiraApp.swift`) so no Xcode project
  surgery is needed; display name is `windoz`. Next: real library data in
  the carousel, app icon, ambient blur from selected art.
- [ ] **Phase 3 — Steam.** Login (password + Steam Guard, QR optional), owned
  library with cover art.
- [ ] **Phase 4 — Downloads.** Pausable/resumable downloads, integrity
  verification, BGContinuedProcessingTask + Live Activity (title, percent,
  speed, ETA).
- [ ] **Phase 5 — Doz Dock.** Madeira Dock ported/renamed/improved; official
  Steam-DRM games launch through Valve's own client running in Wine.
- [ ] **Phase 6 — Settings & polish.** Graphics options, storage management,
  log export, Steam account management.
- [ ] **Phase 7 — Per-game options & logging.** Per-game Wine/DXMT options,
  resolution scale, frame cap; MetalFX upscaling if feasible (stretch).

## Steam scope

- Downloads: fully headless for **all** owned games (no Steam app involved).
- Launch: DRM-free games start directly; Steam-DRM games launch through Doz
  Dock (Valve's own Windows Steam client running inside Wine). No Steam or
  DRM emulation, ever.

## Build steps (local)

Requires a Mac with Xcode 26. The CI workflow (`.github/workflows/build.yml`)
is the authoritative recipe; every step above is a script you can run in
order from a clean recursive clone.

## Known issues

- **CI run #1 failed** at "Build LLVM for iOS": `ninja: error: unknown target
  'llvm-min-tblgen'` — that target doesn't exist in the pinned LLVM revision
  (pre-17). Fixed: host build now produces `llvm-tblgen` only, and the iOS
  cross build receives it explicitly via `-DLLVM_TABLEGEN`.
- **CI run #2 failed** at "Build LLVM for iOS" configure: `install TARGETS
  given no BUNDLE DESTINATION for MACOSX_BUNDLE executable target
  "llvm-tblgen"` — iOS CMake wants executables installed as app bundles.
  Fixed: `-DLLVM_INSTALL_TOOLCHAIN_ONLY=ON`.
- **CI run #3 failed** at "Build LLVM for iOS" link: `ld: unknown options:
  --gc-sections` — LLVM's `add_link_opts()` checks
  `CMAKE_SYSTEM_NAME MATCHES "Darwin"`, which is false for iOS, so Apple
  targets got the GNU dead-strip flag; Xcode 26's linker rejects it. Fixed:
  `-DLLVM_NO_DEAD_STRIP=ON` (we never install or size-optimize the tools).
- **Full clean-build audit (after run #3).** Every remaining script was read
  and the pipeline reordered to honour dependencies Madeira's build record
  did not state (their dev machine had these trees lying around):
  - `wine/build-macos` (configured Wine tree) must exist before the unix-side
    builds — created as a symlink alias to `wine/build-arm64ec` after the
    latter is configured;
  - widl-generated headers (`dwrite.h`) require building `dlls/dwrite` before
    `build/ntdll-unix/build.sh`;
  - `build/freetype-ios/build.sh` requires a freetype 2.13.3 clone in
    `research/freetype` (not vendored) — the pipeline clones the pinned tag;
  - `build/wineserver/build.sh` patches an existing `libwineserver.a` base
    archive that is not tracked — `scripts/build-wineserver-base.sh` now
    compiles it from `wine/server/*.c` first;
  - `build/madeira-d3d12/fetch-converter.sh` requires Apple's installer
    package and is NOT run (the iOS converter dylib and headers are tracked
    and hash-verified via `deps.sh` already);
  - the DXMT PE build precedes `madeira-d3d12/build-pe.sh` (winemetal import
    library); `llvm-mingw`'s bin is on PATH for the whole chain (wineserver's
    objcopy symbol-rename sweep needs it);
  - `ccache` added to the CI brew install (FEX builds pass ENABLE_CCACHE=ON).
- **Open watch-item RETIRED (pre-fixed after inspecting the Xcode project):**
  nothing in the audited scripts creates the initial
  `app/Madeira/libdxmt_combined.a` (the project only links it; the DXMT
  script only refreshes an existing copy). New
  `scripts/build-dxmt-combined.sh` selects the LLVM archives airconv needs
  by symbol closure from `libdxmt_unix.a` and merges them with Apple's
  `libtool -static`.
- **CI run #4 failed** at "Build LLVM for iOS" link: `FAILED:
  lib/LLVMHello.dylib` — `ld: unknown file type in '.../LLVMHello.def'`.
  LLVM's export-file logic uses `APPLE` in some places (true on iOS) and
  `CMAKE_SYSTEM_NAME MATCHES "Darwin"` in others (false on iOS); the module
  branch emitted a Windows `.def` file to Apple's linker. Every LLVM *tool*
  linked fine at this point. Fixed: `-DLLVM_ENABLE_PLUGINS=OFF` (no loadable
  modules are needed; DXMT links LLVM statically). Also fixed the Wine
  `dlls/dwrite` header build to use Madeira's own `make -C <dir>` pattern.
- **CI runs #5 (both attempts) never executed**: GitHub's macOS ARM64 fleet
  could not provide a `macos-26` runner ("The job was not acquired by Runner
  … capacity constraints"), so the jobs were cancelled in queue/after ~15 min
  with zero steps run. Not a build issue. Fixed: switched to the
  higher-capacity `macos-15` image, with a hard guard that fails loudly if
  Xcode 26 (iOS 26+ SDK) is missing from the image.
- **CI run #6 failed** at "Build LLVM for iOS" linking `lib/libLTO.dylib`:
  `ld: unknown options: -z` (`-Wl,-z,defs`) and `ld: unknown file type in
  'LTO.def'` — the same Apple/iOS mismatch as runs #2/#4, one layer deeper:
  LLVM 16 treats only `CMAKE_SYSTEM_NAME == "Darwin"` as Apple, and iOS is a
  separate name, so shared libraries got GNU linker flags and Windows `.def`
  export files. (Note: the macos-15 image carried Xcode 26.3 / iPhoneOS26.2 —
  the SDK guard passed.) Fixed: a small idempotent patch to the LLVM checkout
  makes its CMake treat iOS as Apple (`HandleLLVMOptions.cmake`,
  `AddLLVM.cmake`); documented here, applied after checkout in
  `scripts/build-llvm.sh`.
- **CI run #7 failed** AFTER LLVM COMPLETED (the iOS patches work!) at
  "Fetch VC++ x64 runtime DLLs": 7-Zip can no longer extract Microsoft's
  2022 `vc_redist.x64.exe` (WiX 4 burn container). Fixed: the DLLs ship as
  the `vc-runtime-inputs` release asset on this repo (from the owner's
  licensed Windows System32, redistribution permitted by Microsoft's
  redist terms), downloaded hash-verified by the fetch script. Provenance
  note staged alongside the DLLs.
- **Backup CI**: `azure-pipelines.yml` mirrors the GitHub Actions build
  (same scripts, Azure-hosted Mac). Requires the free hosted-parallelism
  grant for public projects (approval is not instant — see README).
- **CI run #8 failed** in "Build runtime" at `dlls/ntdll/ntdll.so`:
  `ld: symbol(s) not found for architecture arm64` — `Undefined: _ios_avail_phys`.
  Madeira's `build/wine-pe/build-ntdll.sh` runs `make -C dlls/ntdll`, whose
  default target also builds the host unix side (`ntdll.so`); that side was
  replaced by Madeira's own `libntdll_unix.a` and the stock one references
  their private iOS symbol, so it can never link from a clean checkout. The
  dev machine never saw this because its tree was already built. Fixed: new
  `scripts/build-wine-ntdll.sh` builds ONLY the PE target
  (`dlls/ntdll/arm64ec-windows/ntdll.dll`) and replicates the strip+pad
  post-processing verbatim; `dlls/dwrite` now builds the same way (its PE
  file target), matching the pattern `build-modules.sh` itself documents
  ("DLL file targets, not dlls/<name>/all").
  - 32-bit (WoW64) support is deferred: `app/Madeira/i386-windows` is not
    tracked upstream (built by the UNVERIFIED wine-i386/fex-wow64 chain), so
    the pipeline creates an empty placeholder folder for the Xcode reference.
    64-bit games are unaffected.
- **CI run #12 failed** at `server_ios.c:2582`:
  `no member named 'ri_page_wait_time_mach' in 'struct rusage_info_v6'` —
  the iPhoneOS 26.2 SDK (macos-15 image) lacks a field that the 26.5 SDK had;
  the use is inside a diagnostics-only process-stats log line. Fixed:
  idempotent build-time patch zeroes that one cosmetic term. Per-file error
  dumps widened to 400 lines so any further SDK surprises are visible at once.
- **CI run #13 failed** at `fex-ios` configure: `Unsupported processor type .`
  — with `-DCMAKE_SYSTEM_NAME=iOS`, CMake leaves `CMAKE_SYSTEM_PROCESSOR`
  empty, so FEX's architecture check fails; and FEX's default
  `TUNE_CPU=native` probes `/proc/cpuinfo`, which "aborts the configure on
  macOS" (FEX's own comment). **Progress note: run #13 completed the entire
  Wine layer** (ntdll-unix with the SDK patch, win32u-unix with freetype,
  all wineserver pieces) — the Wine side of the runtime is proven. Fixed:
  the pipeline pre-configures `FEX/build-ios` with the script's exact options
  plus `-DCMAKE_SYSTEM_PROCESSOR=arm64 -DTUNE_CPU=cortex-a78`; the script
  then skips its own configure and builds.
- **CI run #14 failed** at `fex-arm64ec` (fex-ios PASSED ✅): repeated
  `CMake Error: IMPORTED_IMPLIB not set for imported target "fmt::fmt"` —
  Homebrew's `fmt` on the runner image is found by `find_package(fmt)`, and a
  macOS dylib cannot satisfy FEX's Windows-style ARM64EC cross build, which
  needs an import library. Fixed: the pipeline pre-configures
  `FEX/build-arm64ec` with the script's exact recorded options plus
  `-DCMAKE_DISABLE_FIND_PACKAGE_fmt=TRUE` (and `range-v3`, same trap), making
  FEX use its bundled copies. The workflow now also saves the LLVM cache even
  when a run fails, removing the ~25 min LLVM rebuild tax from every
  iteration until a run succeeds.
- **CI run #15 failed** at dxmt-ios `airconv_context.cpp`:
  `fatal error: 'air_msad.h' file not found` — the airconv embedded-shader
  headers (air_msad/air_samplepos/air_tessellation) are generated by DXMT's
  meson chain (`xcrun metal -std=metal3.1 --target=air64-apple-macos14.0` →
  `xcrun metallib` → `xxd -i`), are not tracked in the fork, and Madeira's
  script only generates dxmt_command.h (the dev machine had them from an
  earlier meson run). **FEX passed fully in this run** (both modules ✅).
  Fixed: the pipeline replicates the exact meson generator chain into
  `build/dxmt-ios/shader-headers/` (already on the compile include path).
  Verified the d3d9 "generated" thunk files ARE tracked in the fork — no
  other missing generated artifacts exist.
- **CI run #16 failed** at the DXMT PE meson setup:
  `Unknown compiler(s): [...dxmt/toolchains/llvm-mingw.../arm64ec-w64-mingw32-clang]`
  — the cross file's `@GLOBAL_SOURCE_ROOT@` resolves to the DXMT project root,
  so it expects the llvm-mingw toolchain at `dxmt/toolchains/`. Huge progress
  first: **the entire DXMT unix side compiled** (airconv, DXBCParser, the
  native D3D9 frontend, `libdxmt_unix.a` archived) and
  `build-dxmt-combined.sh` produced `libdxmt_combined.a`. Fixed: symlink
  `dxmt/toolchains` → `../toolchains` before the meson setup (same alias
  pattern as `wine/build-macos`).
- **CI run #17 failed** at dxmt winemetal meson setup:
  `C shared or static library 'winecrt0' not found` — the meson file searches
  the WINE BUILD TREE at `<build>/dlls/winecrt0|ntdll|dbghelp/arm64ec-windows/`.
  wine's actual `libwinecrt0.a` lives in `libs/wine/` (searched paths miss
  it), and dbghelp was never built (not in GAME_MODULES). Fixed: build
  `libs/wine`, stage `libwinecrt0.a` into the searched location, and build
  dbghelp via `build/wine-pe/build-modules.sh dbghelp` (also refreshes the
  tracked farm copy).
- **CI run #18 failed** at `make libs/wine`: `No rule to make target
  'libs/wine'` — my staging step used the wrong directory; in this Wine fork
  winecrt0 lives in `libs/winecrt0/` (its archive `libwinecrt0.a`, already
  built by the ntdll PE link). Fixed: locate the archive anywhere under the
  wine build tree, stage copies into both meson search paths
  (`libs/winecrt0/arm64ec-windows/` and `dlls/winecrt0/arm64ec-windows/`),
  build it via file target if absent, and keep the dbghelp build.
- **CI run #19 failed** at a `cp` in my own staging code: the `find` located
  `libwinecrt0.a` at exactly the meson search path, and the copy was
  self-identical (BSD cp errors, `set -e` aborts). **`libdxmt_combined.a`
  was created successfully** (59.6 MB, ~30 LLVM archives via symbol closure).
  Deeper root cause found for run #17's find_library failure: DXMT resolves
  `-Dwine_build_path` against the DXMT source root, so the recorded relative
  `../../wine/...` escapes the repository. Fixed: absolute `wine_build_path`
  passed to meson, and the self-copy guarded.
- **CI run #20 failed** at the Xcode app build: Swift could not parse
  `StikJIT.swiftmodule/arm64-apple-ios.private.swiftinterface`
  (`expected '{' in struct`) — the vendored StikJIT 1.9.0 framework was built
  with **Swift 6.4** (Xcode 26.6); macos-15's newest Xcode is 26.3 (Swift
  6.2), and Swift 6.4 interfaces use qualified-type syntax older compilers
  cannot parse. Everything before the app build passed: **DXMT PE ✅, Wine
  Mono ✅, rppairing ✅, D3D12 ✅, stubs ✅**. Fixed: back to `macos-26`
  (Xcode 26.6 / iPhoneOS 26.5 — the author's own SDK; capacity crunch from
  Oct 15 was transient). The `server_ios.c` SDK patch is unconditional and
  harmless on 26.5.
- **CI run #21 failed** at the FINAL app link: `ld: library 'JemallocLibs'
  not found` — FEX's root CMake disables the JemallocLibs target on Apple
  (system allocator), but the app's Xcode project links it unconditionally;
  the dev machine's copy was a stale artifact from an earlier FEX config.
  The Apple FEXCore references no jemalloc symbols, so the pipeline now
  creates an empty stub archive. **Everything else in run #21 passed:
  Xcode 26.6 parsed the StikJIT interfaces, all Swift compiled, and the app
  linked down to this single library.**
- **CI run #22 failed** at the final link: `Undefined symbols:
  FEXCore::Allocator::{malloc,free,aligned_alloc,aligned_free,memalign}` (from
  FEXCore's allocator-aware fextl — defined in FEX's
  `Utils/AllocatorHooks.cpp`, which FEX's CMake only compiles into the
  Apple-disabled JemallocLibs target) and `_setupterm/_set_curterm/
  _del_curterm/_tigetnum` (LLVM color detection; the iOS SDK has no
  terminfo). Fixed: the stub archive now contains FEX's own
  `AllocatorHooks.cpp` compiled WITHOUT `ENABLE_FEX_ALLOCATOR` (the
  system-malloc passthrough — identical to FEX's JemallocDummy target) plus
  terminfo stubs returning "no colors".
- **CI run #23 failed** at a Xcode build phase:
  `bundled LICENSE-MADEIRA-GPL-3.0.txt is missing or stale; run
  build/stage-licenses.sh` — the licence-staging step was accidentally
  dropped when `fetch-converter.sh` was removed (they are unrelated: staging
  copies pure text files and needs no Apple package). **The final app link
  SUCCEEDED past all symbols** — the allocator hooks and terminfo stubs
  resolved everything. Fixed: `build/stage-licenses.sh` runs before the app
  build.
- **REWORK (2026-10-16):** the app is being rewritten from scratch per the
  owner's spec — original UI, stores, downloads and settings; the engine
  forks stay pinned as submodules behind the `WindozEngine` boundary
  (`app-windoz/`, XcodeGen project). JIT v1 = StikDebug deep link + on-device
  probe; built-in helper comes later. Session hosting (game rendering +
  input) is being ported behind the engine API incrementally — until that
  port completes, Play honestly reports "engine core only".
- **CI run #31 failed** at the app link: 33 undefined symbols in two groups —
  (1) none of the engine `.a` archives listed in the XcodeGen *sources* phase
  were actually linked (Xcode silently skips `.a` there; confirmed because the
  terminfo stubs in `libJemallocLibs.a` never resolved either), and (2)
  `ios_dump_all_thread_stacks` (Winios main-stall hook) has no definition in
  the public repository. Fixed: all engine archives are now linked explicitly
  by file path in `OTHER_LDFLAGS`, in dependency order, with `-force_load`
  for `libFEXCore.a` (its LTO members need unconditional pulling); an original
  `WiniosShims.c` implements the stall dumper (Mach thread walk + dladdr
  symbolisation).
- Later failures will be recorded here as they are diagnosed and fixed.

## Built-in JIT (in-app)

Inherited from Madeira, included in every windoz build:

- **Built-in StikJIT** — a bundled app extension (`JITHelper.appex`) enables
  JIT without the separate StikDebug app. Requires iOS 26+, a normal
  sideloaded install, and **LocalDevVPN** (App Store) for the loopback.
- **Pairing**: on iOS 27 the app can pair with the iPhone by itself (in-app);
  on iOS 26 a pairing file made on a computer (e.g. JitterbugPair on Windows)
  is imported in Settings → JIT → JIT setup.
- **StikDebug** remains supported as an alternative method.
- Sideload with SideStore/AltStore/Sideloadly **keeping app extensions** (the
  helper must survive); the bundle id is `com.milifrr.windoz` and the helper
  follows it automatically.
- If `macos-26` is not yet a valid GitHub runner label, switch to
  `macos-15` + newest Xcode 26.

## Licensing summary

| Component | Licence | Obligation for windoz |
|---|---|---|
| Madeira app + our new code | GPL-3.0-or-later + Converter Exception | Public source when distributing; keep exception text |
| Wine fork (madeira-lgpl), GnuTLS, FFmpeg | LGPL-2.1+ | Keep build recipes public so recipients can rebuild/relink |
| FEX / DXMT / rpmalloc fork changes | GPL-3.0-or-later + exception | Same as app |
| StikJIT | MPL-2.0 | Notices |
| idevice, zstd (BSD-3), LLVM | MIT / BSD / Apache-2.0 | Notices |
| Apple Metal Shader Converter | Apple proprietary (agreement) | Apple devices only; dlopen; keep agreement + NOTICE |
| VC++ runtime DLLs | Microsoft redistributable terms | Distributed as the `vc-runtime-inputs` release asset (from the owner's licensed Windows install, SHA-256 pinned in the fetch script); never committed to the tree |

Rules: keep the licence bundle and per-file headers; do not push AI-assisted
fork changes upstream to FEX-Emu (their policy); never add DRM-circumvention
code.
