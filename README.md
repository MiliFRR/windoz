# windoz

A Windows game launcher and runner for iPhone. Sign in to Steam, browse your
library in a console-style UI, download games in the background, and run them
locally — unmodified — on a jailed iPhone (iOS 26+, sideloaded only).

**Status: green build (2026-10-17).** This repository was recreated empty on
2026-10-16; `main` was then re-pushed from the developer's clone and the
`vc-runtime-inputs` release behind `scripts/fetch-vcruntime.sh` recreated
(its download hash matches the pin). The whole pipeline now runs green in
**this** repository as restored: run #2 of `build-ipa.yml` (`main` = `f720d53`)
completed every stage — LLVM for iOS, llvm-mingw, the hash-verified VC++
runtime fetch, "Build runtime" (Wine/ARM64EC PE tree, wineserver, FEX for iOS
and arm64ec, DXMT's unix and PE sides, Wine Mono, the Rust pairing library, the
native D3D12 core, the stub DLLs, licence staging), "Build app" and "Assemble
IPA" — and uploaded a ~70 MB unsigned `windoz.ipa` (`windoz-unsigned-ipa`
artifact, 14-day retention; download it from that run's page). Even with a
cold LLVM cache the run took under 50 minutes.

An unsigned IPA that **builds** is the claim — no more. Running it on a device
(sideload, JIT, launching anything) is not proven here yet, and hosting a full
game session (rendering + input) is the remaining engine port; Play reports
that honestly. The run-by-run ledger, including what the first restored-repo
runs and the new typecheck gate caught, is in **Known issues** below.

**On-device status (LiveContainer, 2026-10-17):** the launch-crash fix was
confirmed by the owner — the app opens. **Steam is now a real client, not a
stub:** sign-in (password + Steam Guard, or a QR code), the account's owned
library, and headless depot downloads into the prefix in Valve's own
`steamapps` layout, with journaled resume and per-chunk SHA-1 verification
(`Sources/Steam/`, wired in `Sources/Stores/SteamStore.swift`). Device
verification of the download path is pending the owner's first run; starting
Steam games still needs the session host. **Epic is real too, up to the
library:** sign-in is a device code approved on Epic's own website — no
password is ever typed into the app — and the owned library lists with real
art (`Sources/Epic/`, wired in `Sources/Stores/EpicStore.swift`); Epic's
chunked downloads are the next piece and the UI says so. The remaining stores
stay honest stubs.

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
- [`docs/SIDELOADING.md`](docs/SIDELOADING.md) — getting the CI's IPA onto an
  iPhone (Sideloadly / SideStore / LiveContainer), JIT via StikDebug, and the
  free-Apple-ID realities.
- [`docs/DOZDOCK.md`](docs/DOZDOCK.md) — what Doz Dock is, what exists today
  (the download engine; Steam as a real native client; Epic and the launcher
  stores as honest stubs), and the rules it will keep (no DRM circumvention,
  no fake clients).

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
5. `scripts/build-windoz-app.sh` — generates the Xcode project from
   `app-windoz/project.yml` (XcodeGen) and makes an unsigned **Debug** build
   (the configuration that runs games). The bundle id is
   `com.milifrr.windoz`; the JIT helper, when it lands, will follow it.
6. `scripts/assemble-ipa.sh` — packages the built app into `windoz.ipa` as
   `Payload/Windoz.app` (it still understands the legacy `Madeira.app`),
   uploaded as a CI artifact.

## Phases

- [x] **Phase 0 — Reproducible build.** CI produces an installable IPA from a
  clean clone — first proven in the pre-restore pipeline (ledger below), and
  re-proven in the restored repository: run #2 of `build-ipa.yml`
  (`main` = `f720d53`) went green end-to-end in under 50 minutes on a cold
  LLVM cache and uploaded the ~70 MB unsigned `windoz.ipa`
  (`Payload/Windoz.app`). The LLVM cache is saved across runs, so later builds
  skip the ~25 min LLVM compile.
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
- [ ] **Phase 3 — Steam (code complete; device verification pending).** Login
  (password + Steam Guard, QR), owned library with cover art, and headless
  depot downloads — the SwiftSteam port in `app-windoz/Sources/Steam/`, wired
  by `SteamStore.swift`. Awaiting the owner's first on-device run before this
  is called done; see the ledger.
- [ ] **Phase 4 — Downloads (Steam side mostly done; generic pipeline still
  open).** Depot downloads are resumable (journals) and verify every chunk
  against its SHA-1; the generic engine keeps its queue/verify rules for
  runtime files. BGContinuedProcessingTask + Live Activity for depot
  downloads and pause-from-UI are still open.
- [ ] **Phase 5 — Doz Dock.** Madeira Dock ported/renamed/improved; official
  Steam-DRM games launch through Valve's own client running in Wine
  (design and honest state: [`docs/DOZDOCK.md`](docs/DOZDOCK.md)).
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

Requires a Mac with Xcode 26. The CI workflow (`.github/workflows/build-ipa.yml`)
is the authoritative recipe; every step above is a script you can run in
order from a clean recursive clone — or simply `make ipa` (see the
`Makefile`; `make entitlements` checks the signing plist).

## Automation

| Workflow | What it does |
|---|---|
| [`build-ipa.yml`](.github/workflows/build-ipa.yml) | The full chain on a cloud macOS runner: LLVM, llvm-mingw, the VC++ runtime, Wine/FEX/DXMT/D3D12, the app, the `windoz.ipa` artifact. |
| [`typecheck.yml`](.github/workflows/typecheck.yml) | Fast `swiftc -typecheck` + XcodeGen validation on `ci-*` branches — minutes instead of hours. |
| [`issue-watcher.yml`](.github/workflows/issue-watcher.yml) | The self-healing loop. A failed `main` build, or a new owner-authored (or `autofix`-labelled) issue, is read by an AI agent; it writes the fix on an `autofix/…` branch; the full macOS build is dispatched on that branch; and **only a build-verified change is squash-merged to `main`** and reported back on the issue. If the attempts do not pass, it says so in the issue (or opens one). |

Controls live in **Settings → Secrets and variables → Actions**:

- `AUTOFIX_ENABLED=false` (variable) switches the watcher off.
- `AUTOFIX_MODEL` (variable) picks the agent model. The default,
  `opencode/deepseek-v4.1-flash-free`, needs no secret; a paid model needs
  `OPENCODE_CONSOLE_TOKEN`. Expose nothing else — anything in the environment
  is reachable by the agent's shell.
- Adding the `autofix` label to an issue is the explicit "fix this one";
  without it, only owner/member/collaborator issues are picked up.

The watcher treats issue text and build logs as **untrusted data** (prompt
injection), runs the agent with a deny-list (no `curl`/`wget`/`ssh`, no `gh`,
no `git push`), and the workflow — not the agent — pushes, verifies and merges.

## Known issues

*Operational note (2026-10-17): when this repository was next looked at, the
GitHub side had been emptied again — no commits, no runs, and the
`vc-runtime-inputs` release gone. `main` was pushed back from the working copy
(so the history below is the history again), the release was re-created from
the locally kept zip whose SHA-256 still matches the pin in
`scripts/fetch-vcruntime.sh`, and Actions run numbering restarts at #1 for the
restored repository.*

*Diagnosed failures from the previous incarnation of this repository (its run
numbers, #1–#35, no longer exist — this repository was recreated on 2026-10-16
and its runs restart at #1). Kept because each entry records a root cause and
the fix that is still in the tree.*

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
  `scripts/build-dxmt-combined.sh` merges the DXMT objects with the LLVM iOS
  archives with Apple's `libtool -static`. (The first version of that script
  selected the archives by symbol closure instead of following
  `build/dxmt-ios/README.md`'s "all of `llvm-ios-build/lib/*.a`" — that is what
  broke the app link in run #4; see the newest entry below.)
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
- **CI run #4 (this repository, `main` = `102826f`) passed "Build runtime"** —
  Wine/ARM64EC, wineserver, FEX (iOS + arm64ec), the DXMT unix and PE sides,
  Wine Mono, the Rust pairing library, native D3D12, the stub DLLs and the
  licence staging all built — and **failed at "Build app"** with 7 undefined
  symbols, all from `dxmt::runOptimizationPasses` in
  `libdxmt_combined.a(airconv_context.o)`:
  `llvm::PassBuilder::PassBuilder(llvm::TargetMachine*, …)`,
  `llvm::PassBuilder::register{Module,CGSCC,Function,Loop}Analyses(…)`,
  `llvm::PassBuilder::crossRegisterProxies(…)` and
  `llvm::PipelineTuningOptions::PipelineTuningOptions()`. Root cause: on a clean
  checkout nothing creates `libdxmt_combined.a`, so `scripts/build-dxmt-combined.sh`
  built it from a *symbol closure* of `libdxmt_unix.a`'s undefined symbols —
  which resolved 30 of the ~70 LLVM archives but never reached
  `libLLVMPasses.a`, the archive those seven symbols live in (airconv's new pass
  manager is reached through other LLVM members, not directly from one DXMT
  object). Fixed: the script now follows `build/dxmt-ios/README.md`'s documented
  recipe — `libtool -static` over the DXMT objects plus **every** archive in
  `toolchains/llvm-ios-build/lib` — still printing the old closure as
  information only, and failing loudly if `libLLVMPasses.a` is absent. Linking
  member-by-member means unused archives cost nothing.
- **Why that archive was missing at all** (found while reading run #1's steps):
  run #1 restored no LLVM cache, started building LLVM, and was cancelled 22
  minutes later by the next push — but the `Save LLVM cache (even on later
  failures)` step still ran and wrote the *partial* `llvm-ios-build` tree under
  the version-3 key. Every run since restored that incomplete tree and skipped
  the LLVM step, which is why "Build runtime" succeeded (Wine/FEX/DXMT need
  LLVM's headers and only some archives) while "Build app" could not link
  airconv. Fixed twice over: the cache key moves to **v4** (a fresh entry) with a
  `restore-keys` fallback so the old tree is *completed* rather than discarded,
  and the LLVM step now **always runs** — `build-llvm.sh` is idempotent and ends
  in an incremental `cmake --build`, so a complete tree costs seconds and a
  partial one is finished in place instead of failing the link an hour later.
- **Same run, non-fatal warnings worth knowing:** the app was linked with
  Xcode 26's *debug dylib* mode (`Windoz.app/Windoz.debug.dylib`). An unsigned
  IPA with a second Mach-O gives sideloading tools — LiveContainer included —
  something else to re-sign for no benefit, so `project.yml` now sets
  `ENABLE_DEBUG_DYLIB: NO` and links one ordinary app binary. `ld` also warns
  that the LLVM archives were built for iOS 26.5 while the app targets 26.0
  (harmless: only the SDK's minimum-version stamp), and that Swift autolinks
  `SwiftUICore`, `CoreAudioTypes` and the private `UIUtilities` — all three are
  "cannot link directly with" warnings from Apple's own SDKs, not errors.
- **Restored repository, first Swift error came from the new fast gate, not
  the full build:** `typecheck.yml` run #1 (red, `main` = `07d8364`) failed
  with `app-windoz/Sources/Engine/AppContainer.swift:14:77: cannot convert
  value of type 'URL' to expected argument type 'String'` — the `HOME` branch
  of `AppContainer.home` wrapped `environmentPath("HOME")` in
  `URL(fileURLWithPath:)` a second time even though the helper already returns
  `URL?`. Fixed at `f720d53` (`return path`, exactly like the `LC_HOME_PATH`
  branch above it); typecheck run #2 went green in a few minutes of runner
  time. The full build never paid for this one. *(Numbering note: the
  repository restore and the `build.yml` → `build-ipa.yml` rename gave the
  workflows new identities, so their run numbers restarted at #1 — older
  "run #N" entries in this ledger refer to the previous identities.)*
- **Restored repository, first full run — green end-to-end (2026-10-17):**
  `build-ipa.yml` #2 (`main` = `f720d53`) passed every stage — the cold LLVM
  build (cache v4 started empty in the restored repo), llvm-mingw, the VC++
  fetch (hash check included), Build runtime, Build app, Assemble IPA — and
  uploaded the ~70 MB `windoz-unsigned-ipa` artifact: one `Windoz` binary (no
  debug dylib), the Wine ARM64EC tree, D3D12 plus Metal Shader Converter, the
  14 x86_64 VC++ runtime DLLs, the licence bundle and the staged
  `madeira-jit.js`. Under 50 minutes wall, cold cache. The pre-fix run #1
  (`07d8364`) was cancelled on purpose rather than left to burn a runner.
- **First on-device launch report (LiveContainer, 2026-10-17): the app quit
  immediately; the audit found the one launch-path operation that can kill the
  process by itself, and it is fixed — confirmed on device.** The
  build that was run contained a `windoz_jit_probe()` that mapped one RWX page
  and executed a tiny function from it to "prove" JIT by execution. On iOS 26
  that is exactly what the platform rejects — the engine's own `JITAllocator`
  documents that self-mapped RX pages fault-loop ("TXM rejected self-mapped RX
  pages") — and the probe ran on **every** trip through the console
  (`ConsoleRootView.task` → `refreshStatus`), JIT on or off. Every other
  launch-path operation is plain file/syscall work. Fixed by replacing the
  probe with the engine's own safe readiness rule (Madeira's
  `StikJITHelper.ready`): sticky `CS_DEBUGGED` **and** a debugger attached
  right now (`P_TRACED` via `sysctl`) — nothing is mapped, nothing is
  executed, and the check cannot kill the process. Settings now also
  distinguishes "JIT was enabled but the debugger left" (the state StikDebug's
  app-list mode leaves behind) instead of treating the sticky flag as ready.
  The next IPA carried the fix, and the owner confirmed it on device: the app
  opens in LiveContainer.
- **The store clients were honest stubs; Steam is now real (2026-10-17).**
  The owner asked for native store sign-in and owned-game downloads. Root
  cause was scope, recorded plainly: the store layer shipped as truthful stubs
  while the engine port came first, and the UI said so. Fix: Madeira's pinned
  SwiftSteam client (commit `279fd0f8`; GPL-3.0-or-later + Converter
  Exception, per-file headers kept) is ported into
  `app-windoz/Sources/Steam/` — password + Steam Guard (code or in-app
  approval) and QR sign-in with the token in the Keychain
  (`windoz.steam.tokens`), the CM connection, PICS app info, the license
  list, and the depot downloader (key/manifest auth, VZip/VZstd/PKZip chunk
  decryption with the ported LZMA/zstd helpers, Steam's own
  `appmanifest_<appid>.acf` install record) — and wired as a real
  `SteamStore`: owned library with real art, per-game Install with live
  progress and a one-at-a-time queue, resume from journals, Update (manifest
  diff — only changed chunks), Verify (every existing chunk re-read against
  its SHA-1 before it is skipped), Uninstall; finished games register in
  Windoz's library in `C:\Program Files (x86)\Steam\steamapps` inside the
  prefix. The first typecheck of the port caught exactly one error (a
  `Task<()?, Never>` vs `Task<Void, Never>` in the queue), fixed in `5a6e47d`
  and re-dispatched clean. Device confirmation of the download path is
  pending. Epic was the next piece: no reusable client exists in the engine,
  so it is a from-scratch build — see the entry below.
- **Epic: device-code sign-in and the owned library are real (2026-10-17).**
  Steam shipped first; Epic follows it under the same rule — nothing is
  claimed that was not exercised. The flow was verified against the live API
  before any UI was written: Windoz fetches a client token, asks Epic for a
  device code, the owner approves it on `epicgames.com/activate`, and Epic
  issues the session to the owner's own account. Only the refresh token is
  stored, in the Keychain (`epic.session`); the owner's password is never
  typed into the app and never seen by it. The owned library is the account's
  own library-service records; titles, developers and art come from the
  public catalog service, which accepts plain client credentials (probed
  live — no account context needed for that call). The UI lists owned titles
  with art and says plainly that chunked downloads are the next piece:
  Epic's launcher/CDN endpoints answered 403 to a device-flow session during
  development (they are scoped to Epic's launcher client), so the downloads
  round starts by settling that second, launcher-scoped authorization (the
  approach Legendary uses). Device verification of sign-in and the library is
  pending the owner's next run.
- **Steam+Epic build bounced at launch on device (2026-10-17).** Build #6
  (`7f139c7`) throws the user back to the home screen a moment after launch in
  LiveContainer, with or without JIT; the Steam-only build (#5, `5a6e47d`)
  and the pre-store build both launch fine, so the regression lives inside the
  Epic commit's delta (`5b674e0`) or its effect on the launch path. Static
  review found nothing load-time outside the registry's `EpicStore`
  construction, whose keychain read matches patterns that already run in the
  working builds. This build adds a boot breadcrumb (`BootTrace`, one line per
  step in `Documents/windoz-boot.log`) and a gate screen that shows the
  previous session's log before any store code runs, so one bounce names the
  exact step; root cause and fix follow the evidence. The gate disappears once
  the crash is fixed.
- **Steam download hit a write-permission error on device (2026-10-17).**
  Starting a download on the Steam-only build failed with Foundation's
  "You don't have permission to save the file … in the folder “common”"
  (error 513, EACCES) when the downloader created `steamapps/common/<game>`
  inside the Wine prefix. The shipped `prefix-template.tar.gz` extracts every
  directory owner-writable (verified entry by entry), so the cause is on the
  device's data, not in the template. This build adds `PrefixHealth`: it
  reports each level's mode and owner, re-adds owner access, probes the exact
  failing operation, logs the detail, and retries the download once — a
  repaired path or an exact diagnosis, never silence. Device confirmation
  pending.
- **JIT status could read "off" while still checking (fixed in this build).**
  Running the engine-core test queues work on the engine's serial queue, and
  the status probe shared that queue: the JIT/memory rows sat at "Checking…"
  (and the top banner said "JIT is off") until the core test finished. Probes
  now run on their own queue and the "off"-style UI only appears when the
  probe has actually answered. Device confirmation pending.
- Later failures will be recorded here as they are diagnosed and fixed.

## JIT

What this build actually offers, in order of what works:

- **StikDebug** (a separate app) is the route that exists today. Windoz builds a
  `stikdebug://enable-jit?bundle-id=…&pid=…&script-data=…` URL whose script is the
  engine's `madeira-jit.js` (bundled as a resource), and re-probes JIT on every
  launch. This is the only route inside **LiveContainer** (`LC_HOME_PATH` is set
  there and a guest app cannot start a nested extension).
- **A bundled helper extension** (`JITHelper.appex`) is *not* part of this build:
  `app-windoz/project.yml` has no extension target. `JITManager.builtInHelperUsable`
  therefore reads the bundle and reports false, and the UI offers StikDebug only.
  When the helper target is added the choice appears by itself.
- **LocalDevVPN** (App Store) would be required for the helper's loopback, and is
  not needed while the helper is absent.
- Sideload with SideStore/AltStore/Sideloadly; the bundle id is
  `com.milifrr.windoz`. Any per-app extension would have to survive re-signing —
  another reason JIT currently goes through StikDebug.
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
