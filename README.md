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

An unsigned IPA that **builds** is the claim — no more. Everything past that
(sideloading, JIT, rendering a live game session, store data) is stated
per-item in the ledger below, and every claim says which build and which run
it rests on. The run-by-run record, including what the first restored-repo
runs and the new typecheck gate caught, is in **Known issues** below.

**On-device status (LiveContainer, 2026-10-17 — build 0.3.3):** the app
launches, JIT and increased-memory report Ready, Steam signs in natively with
the full owned library rendering real art, and Epic's sign-in survives a
restart. Two device findings drove the next round: the **Epic owned-library
call was refused (HTTP 403)** with the device-flow session — the service is
scoped to Epic's launcher client — and every store page still said launching
"needs the session host". **Build 0.3.4 carries the missing half of both:**
the game session host is ported (presentation, input, the guest process — see
the ledger), so a game in the library can actually be started and played;
Epic gains the launcher-scoped sign-in its library demands; the Steam game
page reads achievements and friends; and the Stores UI was rebuilt (in-code
store icons, sign-out tucked into Settings → Accounts and per-store ellipsis
menus). Everything in 0.3.4 is **device-verification pending**, and two open
device matters will touch the same run: this LiveContainer container has
refused writes at policy level since 0.3.2 (every location, `EPERM` — see the
ledger), which gates importing or installing the game a session would run,
and 0.3.3's launch-time write-audit was built to name any writable location —
its device result has not been reported yet.

**On-device status (LiveContainer, 2026-10-18 — build 0.3.4):** the owner ran
the session host on the phone; the five findings it produced are each recorded
below with a root cause, and **Build 0.3.5** answers them: Epic's launcher
sign-in now reads the authorization code from the redirect page's JSON body;
the session screen updates its stage line through every startup step, starts
on its own queue, refuses a session with the reason when the container refuses
writes, and a watchdog ends a stalled launch with the stage's name; the
library index is written with verified writes, mirrored into the Keychain and
decoded forgivingly, so restarts and upgrades cannot wipe the shelf;
re-installs say "checking files already on the device" and time themselves
honestly; Steam installs fetch cover art from Steam's own CDN; and the
per-game settings sheet grew real controls (frame pacing through the engine's
own call, nine per-launch engine variables) with every stored-not-applied item
labeled as such. 0.3.5 is **device-verification pending**; its IPA is
`build-ipa.yml` run #14 (`dbc5c22`, success, 2026-10-18), kept at
`windoz-ipa-keep/windoz-14.ipa` (75,129,142 bytes, SHA-256
`C17EBEB8EEC561F2B7C0B0CD3F164C7027D1C39DBAB31FA7972C538995B9C961`).

**On-device status (LiveContainer, 2026-10-18 — build 0.3.5):** the owner ran
0.3.5. Two answers came back: **Epic's launcher sign-in finishes** (reading
the code from the redirect page's body works), and **pressing Play on a game
was still refused with the storage message** — the launch gate found the
prefix unwritable and said so, exactly what the container has done to
`Documents` since 0.3.2, and the honest refusal was the whole of it: every
build up to 0.3.5 hard-coded the Wine prefix at `Documents/windoz-prefix`, so
on this device no game could ever start. **Build 0.4.0 replaces the complaint
with negotiation and is the round the owner asked for:** the whole Wine
environment relocates to the first location that *proves* it accepts writes
(a real create-and-replace probe per candidate — `Documents` only wins when
it passes), the old prefix migrates as one unit, and refusals now carry the
raw errno and free space. Steam games gain per-game **Doz Dock** — Madeira's
dock contract ported exactly (the bundled `dockhost.exe`, the
`windoz-dock/launch.auth` handoff, the `[steam-host]` report read back and
translated, Valve's **own** offline mode) — selectable against Steam desktop
(the full client) and Direct; the Steam client's Windows components install
from Valve's pinned CDN in the game's settings; **Epic downloads** arrive
(Legendary-ported binary manifest + hash-verified chunks, landing in
`EpicGames/<title>`); installs and pre-0.3.5 entries backfill **cover art**
from Steam's CDN; and the game page carries an **achievements card under
Play**. 0.4.0 is **device-verification pending** — the run the owner is
about to do is what confirms it; its IPA is `build-ipa.yml` run #15
(`48415aa`, success, 2026-10-18), kept at `windoz-ipa-keep/windoz-15.ipa`
(75,480,343 bytes, SHA-256
`CBCFD1468ABC7FF80486B58CC193B994DE584DA8E05120F059F421EB72A26F11` —
Info.plist `0.4.0` build 4, and the app binary carries the dock handoff
(`windoz-dock`/`launch.auth`), the Epic assets host and `ChunksV5`/`ChunksV4`).

**On-device status (LiveContainer, 2026-10-18 — build 0.4.0):** the owner ran
0.4.0 and sent back the list that shapes 0.5.0: the phone **warms up at idle**
with the app open; a **game can be tapped twice** during the push animation
and stacks a second page (a stray controller Select can re-point navigation);
**a launch gives no visible story** of its steps; JIT still means StikDebug
next door; games on a fresh prefix **need their runtimes installed by hand**;
and the sharpest one — **Epic downloads fail instantly** although sign-in
works. Build 0.5.0 answers every item — the six phases are summarised in its
own ledger entry in **Known issues** below, with the phase-by-phase detail in
`docs/CHANGES.md`.

**Build 0.5.0 shipped — `build-ipa.yml` run #17 (`main` = `7894113`,
success, 2026-10-18):** the full chain built every stage green and the
unsigned IPA is kept at `windoz-ipa-keep/windoz-16.ipa` (78,207,077 bytes,
SHA-256
`F3323EC9D4D06AD42F4BE7E31AD1F4B299EE6EA2E0E9663ECC409BE970FD71D4`).
Verified inside: `Info.plist` `0.5.0` build 5, `MinimumOSVersion` 26.0, the
`windoz://` scheme; `PlugIns/WindozJITHelper.appex` embedded (bundle id
`com.milifrr.windoz.jit-helper`, version 0.5.0 build 5); and the app binary
carries `ChunksV4`/`ChunksV5`, `windoz-dock`/`launch.auth`, `[epic-dl]`,
`windoz-runtimes`, `windoz_rppairing`, `localdevvpn`/`stikdebug`. The first
full build (#16, `62339df`) caught one real release bug the typecheck gate
cannot see — `build/rppairing-ios/build.sh` had been committed without its
executable bit and the step died at "Permission denied" before running a
line — fixed in `7894113` (mode 100755); #17 built it and every stage after
it. 0.5.0 is **device-verification pending**: the checklist above is the
run that confirms it.

**On-device status (LiveContainer, 2026-10-18 — build 0.5.0):** the owner ran
0.5.0 and sent five findings that shape 0.6.0: **launching a game froze on the
launch screen** (and warmed the phone); afterwards Windoz could not be
**relaunched from LiveContainer for a while**; a **game download did not show
up in the Downloads tab**; the **UI was still sized like an iPad app**; and
the phone **still got hot**. Build 0.6.0 answers each — the stall watchdog
that never fired now runs on the main thread and a stuck start-up becomes a
named failure in 160 s with the Windows service stopped; a stalled run
refuses retries by name instead of wedging again; **Quit Windoz**
(failed-launch card, game page, session menu, Settings → Advanced) hands
LiveContainer its slot back at once instead of after a system kill; the
Downloads tab aggregates Steam and Epic installs with a live badge; the log
sink is batched; and the UI is rebuilt phone-first. 0.6.0 is
**device-verification pending**: the build is `build-ipa.yml` run #20
(`4f51018`, green), published automatically as the GitHub Release
[`v0.6.0`](https://github.com/MiliFRR/windoz/releases/tag/v0.6.0)
(`windoz-0.6.0-build6.ipa`, 78,293,503 bytes, SHA-256
`4BB881B58149CA4C07306EA62A9D4BE1B499F584395D201482AC1DFB90653EA6`); the
checklist below is the run that confirms it.

**On-device status (LiveContainer, 2026-10-19 — build 0.6.0):** the owner ran
0.6.0 and reported that the game **still froze on the launch screen** and the
**UI was still oversized**, and asked, in effect, for Madeira's own engine to
play the games. Build 0.7.0 stops using Windoz's launch pipeline: it grants the
JIT pool from the attached debugger, publishes `WINE_IOS_JIT_RX/RW/SIZE`,
detaches the debugger early, and then runs Madeira's exact order —
`wineserver_start` → wait → `wine_process_start` — with **no app-side
`fex_initialize` or `fex_shutdown` anywhere on the path**. The UI is rebuilt as
a compact native iPhone app: system grouped backgrounds and cards, a
large-title Home without the wordmark or hero carousel, a three-column
library, an 82×110 game header with a standard Play button, and system-size
text throughout. 0.7.0 is **device-verification pending**; its build run,
release and keeper hash are recorded in **Known issues** below. The checklist
is the run that confirms it.

**Build 0.7.0 shipped — `build-ipa.yml` run #21 (`main` = `7f5cf67`, success,
2026-10-19):** the full chain built every stage green (LLVM, the runtime,
Wine/FEX/DXMT, the app, the IPA gate) and the unsigned IPA was published
automatically as the GitHub Release
[`v0.7.0`](https://github.com/MiliFRR/windoz/releases/tag/v0.7.0) —
`windoz-0.7.0-build7.ipa`, 78,276,079 bytes, SHA-256
`81ED949EFBCF016CD48B07E69E1F67C550F4004F9F8B026CFC14D6873621DF69`
(kept locally as `windoz-ipa-keep/windoz-18.ipa`, re-checked with
`scripts/check-ipa.py --require 0.7.0 --min-build 7`). Verified inside: the app
bundle and the helper both claim `0.7.0` build 7, `MinimumOSVersion` 26.0, the
`windoz://` scheme, every subsystem marker, and the new launch-path strings
(`[jit-pool]`, `WINE_IOS_JIT_RX`, `jit26_prepare_region`, `MADEIRA_DETACHED`),
so the Madeira-pool launch code is in the shipped binary. **No device claims:**
the owner's next run is the proof.

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
  (the download engine; Steam as a real native client with the dock itself
  ported in 0.4.0; Epic real through its launcher-scoped library and now
  chunked downloads), and the rules it will keep (no DRM circumvention, no
  fake clients).

The engine core (wineserver + FEX), prefixes, JIT probing, runtime
detection, downloads, the game session that runs a game (**ported in
0.3.4** — presentation, input and the guest process behind
`WindozEngine.launch`), the per-game launch modes (**Doz Dock ported in
0.4.0** — the dock host bridge, handoff, report and offline mode), and the
Steam/Epic clients (Steam depot downloads; Epic chunked downloads in 0.4.0)
are real and testable today. Device verification of the newest layers is
pending; the ledger says exactly which claim rests on which run.

## Decisions (recorded 2026-10-15)

| Question | Decision |
|---|---|
| Device | iPhone 17 (A19, 8 GB RAM); deployment target iOS 26, arm64 — every newer iPhone works too |
| Build | GitHub Actions on `MiliFRR/windoz` (macOS runners); no Mac needed |
| Steam DRM games | In scope — Madeira's Dock approach ported and improved as **Doz Dock** (ported in 0.4.0) |
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
- [ ] **Phase 1 — Runtime (session host ported in 0.3.4; device verification
  pending).** Launch a game from the library: `WindozEngine.launch` runs a
  real preflight, starts the guest process and presents it; Settings shows
  JIT + Memory+ status; launch is blocked with a clear message when not
  ready. Honest limits (one session per app run, single-touch + keyboard
  input, graphics switches stored but not applied) are in the ledger.
- [ ] **Phase 2 — UI shell (in progress).** Console-style home with a
  cover-art carousel, focus/selection animation and a dark theme; the Library
  tab lists real games with a stores section and a count badge; the game page
  has Overview / Achievements / Friends tabs and a settings sheet. The app is
  its own XcodeGen project since the 2026-10-16 rewrite (`app-windoz/`) — the
  old Phase-0 `overrides/` shell is no longer how windoz ships. Next: app
  icon, ambient blur from the selected art.
- [ ] **Phase 3 — Steam (sign-in and owned library verified on device; depot
  downloads pending).** Login (password + Steam Guard, QR) and the owned
  library with real art are confirmed on the owner's phone (2026-10-17).
  Depot downloads — the SwiftSteam port in `app-windoz/Sources/Steam/`, wired
  by `SteamStore.swift` — are code-complete but have not had a first device
  install: the container's write refusal on this LiveContainer install (see
  the ledger) still gates it. 0.3.4 adds the game page's achievements and
  friends (Steam Web API with a community-XML fallback); 0.4.0 adds the
  per-game launch modes and backfills cover art for entries installed before
  0.3.5.
- [ ] **Phase 4 — Downloads (Steam side mostly done; Epic's chunked path in
  0.4.0).** Depot downloads are resumable (journals) and verify every chunk
  against its SHA-1; Epic's downloads (ported from Legendary: binary build
  manifest, hash-verified chunks, files assembled at the manifest's own
  offsets) land in 0.4.0; the generic engine keeps its queue/verify rules for
  runtime files. BGContinuedProcessingTask + Live Activity for depot
  downloads and pause-from-UI are still open.
- [ ] **Phase 5 — Doz Dock (ported in 0.4.0; device verification pending).**
  Madeira Dock ported/renamed/improved — the dock host bridge, the handoff
  file, the report mapping and Valve's own offline mode are real per game in
  0.4.0; official Steam-DRM games launch through Valve's own client running
  in Wine. The launcher-in-Wine pipeline for EA/Rockstar/GOG is the next
  piece (design and honest state:
  [`docs/DOZDOCK.md`](docs/DOZDOCK.md)).
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
| [`typecheck.yml`](.github/workflows/typecheck.yml) | Fast `swiftc -typecheck` + the off-device Epic-protocol tests (mocked HTTP, `tests/host/`, since 0.5.0) + XcodeGen validation on `ci-*` branches — minutes instead of hours. |
| [`release-ipa.yml`](.github/workflows/release-ipa.yml) | Publishes every green `main` build as a GitHub Release `v<version>` with the IPA attached (created on the first build of a version, `--clobber`-refreshed on rebuilds) — the keeper is a URL. `build-ipa.yml` itself now runs `scripts/check-ipa.py`, so only check-passing IPAs get published. |
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
  claimed that was not exercised. The flow's API shape was verified live
  before any UI was written — and its client-token half proved wrong on the
  device, corrected in the sign-in entry below. Windoz fetches a client
  token, asks Epic for a device code, the owner approves it on
  `epicgames.com/activate`, and Epic issues the session to the owner's own
  account. Only the refresh token is
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
- **The Steam+Epic launch bounce did not reproduce — kept honest
  (2026-10-17).** Build #6 (`7f139c7`) bounced to the home screen in
  LiveContainer while #5 (Steam-only) ran; the Epic delta became the suspect.
  The next build carried silent boot breadcrumbs (`BootTrace` writes one line
  per launch step to `Documents/windoz-boot.log`), and on the device that
  build — the same combined Steam+Epic code — launched and ran. No crash was
  caught, so no cause is claimed: this stays "not reproduced", not "fixed".
  The breadcrumbs stay in the app and would name the exact step if the bounce
  ever returns.
- **Steam on device: sign-in and the owned library verified; the
  write-permission error is narrowed to create/delete inside the prefix tree
  (2026-10-17).** The owner signed in natively and the full owned library
  rendered with real art. Starting an install still failed with Foundation's
  "You don't have permission to save the file … in the folder “common”"
  (error 513) when the downloader creates `steamapps/common/<game>`. The
  owner exported the device log: every level of the path — Documents,
  `windoz-prefix`, `drive_c`, `Program Files (x86)` — reported `mode=755
  uid=501 owner-w` with `access(W_OK)` passing, `Steam` itself read as
  missing before *and* after the attempt, and the create was still refused;
  the same session could not *delete* an existing staged file
  (`windoz-jit.js` — its copy then answered "already exists"), so "existing
  items inside the prefix resist create/delete" is the observed behaviour;
  the cause is still not named, and nothing below claims it is fixed. Build
  0.3.1 answers with executors instead of another question:
  `SteamLibraryLocator` tests the download location before each install
  (create `steamapps/common`, write a file, delete it — through Foundation
  *and* the C library) and moves the library to the first location that
  passes, remembering it in `windoz-steam-library-location.txt` (in-prefix
  fallbacks stay `C:\` to Wine; the last one sits outside the prefix and
  will arrive as `Z:` later). `PrefixHealth` probes every level through
  both routes, prints raw errno, `st_flags` and a raw `readdir` listing of
  the failing level, keeps its rename-the-broken-level repair, and as a
  last resort renames the whole prefix aside
  (`windoz-prefix.windoz-broken-<ts>`, kept for inspection) and extracts a
  fresh template — never while the engine is running. The C library's route
  is also the fallback for every critical write (install folders, install
  records, the JIT script copy, app downloads). Device confirmation
  pending.
- **The refusals can cover the whole data folder, not just the prefix —
  build 0.3.2 routes around it (2026-10-17).** The owner's next screenshots
  (still from build 0.3.0 — 0.3.1's messages differ, which the version shown
  in About now settles) show the refusals had widened: the diagnostics
  verdict reported the app's own `Documents` folder as `W-DENIED` while
  reading and network downloads kept working, and saving the VC++/.NET
  installers into `Documents/windoz-runtimes` was refused with the same 513.
  0.3.2 answers with three changes: the launch write-check now covers six
  folders (adds `Library` and `tmp`), clears a set immutable flag on folders
  at or below Documents (the flag blocks creates and deletes no matter the
  mode bits) and reports the outcome; the runtime staging and the
  Steam-library negotiation list `Library/` and `tmp/` as last-resort homes
  (reachable in Wine as `Z:` later), so a download can land somewhere real
  even when `Documents` refuses; and the version is printed in the first log
  line, so every exported log names its build. Device confirmation pending.
- **Build 0.3.2 ran on the device: the refusal is the whole container, at
  policy level — and Epic's instant sign-out was a misread, both answered
  (2026-10-17).** The owner's 0.3.2 log settles what three earlier logs could
  not: *every* location the app can name — Documents, Imported,
  windoz-runtimes, LiveContainer, `Library`, `tmp`, and all five
  Steam-library candidates — refused a real write through Foundation (513)
  *and* the C library (raw `errno 1`, EPERM); `readdir` on Documents was
  refused too, `access(W_OK)` was denied, while `lstat` succeeded, the
  process ran as uid 501, and reads plus network downloads kept working
  (CFNetwork's temp file even completed). EPERM from both routes on
  create/delete/enumerate, with metadata reads fine, is not a permissions
  problem any path can route around — it is the container itself refusing
  writes at a policy level on this LiveContainer install, which is why no
  previous workaround could work on this device; the log now says so instead
  of leaving it a mystery. 0.3.3 adds a write-audit at launch (the home root,
  app-group containers taken from our own entitlements, the system and
  shared temp dirs) whose hits are offered to installer staging and the
  Steam-library fallbacks, logs each location's raw refusal, and states
  plainly when *nothing* is writable that the container must be repaired
  (reinstalling LiveContainer and re-adding Windoz normally rebuilds it).
  The same log also shows the Steam sign-in *did* work and the owned library
  loaded — and the Epic "sign in, instant sign-out" is explained in code:
  the library call's HTTP 401/403 was misread as an expired session and
  flipped the UI to signed-out; a service refusing one call no longer signs
  the owner out (the status is shown instead), only a refused refresh grant
  does, and Epic's session now also lives in memory for the run, so a
  Keychain that refuses round-trips (raw OSStatus now logged for every
  operation) can no longer undo a fresh sign-in. Device confirmation
  pending.
- **Runtime installer downloads could not save their file (2026-10-17).**
  The Downloads tab showed "the downloaded file could not be saved" for the
  VC++ / .NET installers: moving CFNetwork's temp file into the container
  answered "you don't have permission". The move now falls back to a plain
  copy through Data, and then to the C library's raw write, with every
  attempt's raw NSError (domain and code) in the log. Device confirmation
  pending.
- **JIT status fix verified on device (2026-10-17).** The probe no longer
  shares the engine queue, and the "off"-style UI only appears when the probe
  has answered — the owner's device shows JIT and increased memory as Ready,
  with no stuck "Checking…".
- **Epic device sign-in: wrong client token; root cause found and fixed
  (2026-10-17).** The device was answered "Sorry, your client does not have
  the proper grant_type for access." — reproduced live from a desktop: the
  device-authorization call carried a bearer minted from the *launcher*
  client, which is not allowed that grant; the same call under Epic's own
  public *console* client issues a device code immediately (verified live: a
  code came back, and a bogus-code poll answers a plain `invalid_grant`).
  Fix: the client token for `deviceAuthorization` now comes from the console
  client; the launcher client stays for the catalog. Device retest pending.
- **Settings simplified (2026-10-17).** The owner asked for a less
  complicated UI. The diagnostic gate screen is gone (the breadcrumbs are
  silent); the main Settings screen keeps Engine (status + JIT setup), the
  LiveContainer setup link, and one "Advanced" page holding the Windows
  environment, runtime staging, downloads rule, diagnostics and the log; the
  Library's store explanation is now a short paragraph.
- **Games are playable: the session host is ported (0.3.4, 2026-10-18 —
  device verification pending).** Every Play press since the rewrite ended at
  "engine core only", because the session host — presenting a Wine window,
  routing input, starting the guest process — was the unported part of the
  engine, and the UI said so. This build ports it as new Windoz code
  (`app-windoz/Sources/UI/GameSessionView.swift` plus the session path in
  `WindozEngine`), with techniques and constants taken from Madeira's own
  front-end where they match (per-file credit headers, like the Steam port):
  a window-level `CAMetalLayer` registered once per process with the engine's
  display shim before the guest's first swapchain, raw UIKit touch mapped 1:1
  (aspect-fit) through the engine's `winios_post_touch_*` events, a hardware
  keyboard (UIKey → virtual key, US layout) plus a small on-screen key row
  (arrows, Esc, Tab, Enter, Space), and the guest process started on the
  engine queue (wineserver → FEX → `wine_exit_status_reset` →
  `wine_process_start`) with the program, arguments, working folder and
  screen size written to the same launch environment the engine reads. The
  session ends on the guest process's own exit and the engine's exit report
  decides the message; "close the game" is Alt+F4, and leaving the session
  screen detaches and says plainly that a still-running guest ends with the
  app. Honest limits, stated in-app too: one session per app run (Wine's
  service state — the UI asks for an app restart), single-touch only, no
  gamepad or software keyboard yet, and the settings that need the engine's
  in-process API (frame cap, sync mode, MetalFX, backend choice) are stored
  but not applied — the launch log says so per session.
- **Epic's library refused the device session on the phone (HTTP 403) — the
  launcher-scoped sign-in answers it (0.3.4, 2026-10-18).** The owner's device
  run showed Epic signed in and the owned-library call refused — the same
  client scoping seen in development: the library service belongs to Epic's
  launcher client, and the device-flow session belongs to a different one.
  Fix: a second, launcher-scoped authorization — a web sign-in in a
  non-persistent web view that returns an authorization code, exchanged for a
  launcher refresh token kept in the Keychain (`epic.launcher.session`). The
  library prefers it and falls back to the device session, and a refusal now
  says the service is scoped to the launcher client instead of looking like
  an expired login. Sign-out clears both sessions. Epic's chunked downloads
  remain the next piece, and the UI still says so.
- **The game page grew achievements and friends; the stores UI got its round
  (0.3.4, 2026-10-18).** The owner asked to see a game's achievements and
  which friends own or play it, and for the Stores tab to look right. The
  game page is now Overview / Achievements / Friends: achievements come from
  Steam's Web API with the stored token (player achievements, schema, and
  the keyless global unlock percentages), falling back to the public
  community XML when the Web API refuses the account; friends playing now
  come from the friend list + player summaries matched to the game's app ID,
  and "owns this game" from a bounded scan (≤ 20 friends, public profiles
  only, cached six hours) that reports "not visible" — never "no" — when a
  profile hides games. Each failure is shown verbatim with a retry; nothing
  is guessed. Stores: in-code monogram tiles replace the generic SF symbols,
  each connected store gets a filled capsule library button, sign-out moved
  one level down (per-store ellipsis menus and Settings → Accounts), and the
  Library tab carries a count badge.
- **The owner's 0.3.4 device run: five findings, five named causes, fixed in
  0.3.5 (device verification pending).**
  - **Epic's launcher sign-in never finished — the code arrives in the page
    body.** The owner's screenshots show Epic's web view landing on the
    `…/id/api/redirect` page and rendering its JSON answer
    (`{"warning":"Do not share this code…", …}`), while the sheet waited only
    for a `?code=` query this flow never sends. Fix: the code page is allowed
    to load and its body text is parsed (`code` or `authorizationCode`, JSON
    first, then a literal key/value match) with a short retry while the page
    renders; a navigation that carries `?code=` is still caught directly. The
    exchange itself (launcher client, stored session) is unchanged.
  - **The session screen could not say where a launch stalled.** The 0.3.4
    line ("Preparing the session…") was written once and replaced only after
    the guest process had started, so the owner's screenshot could not
    distinguish the service-process wait from the CPU translator, the process
    start or a wedged queue. Fix: every startup stage updates the line and the
    log ("Starting the Windows service…" → "Starting the CPU translator…" →
    "Launching the game…"), session startup runs on its own queue so a
    diagnostics stop (a blocking join) cannot hold it, a storage preflight
    refuses a launch with the reason when the prefix itself refuses writes,
    and a watchdog turns a startup stalled over three minutes into an honest
    failure carrying the last stage's name — while a session that draws no
    frame in five minutes gets a spoken warning on the session screen and is
    left running, because a slow first boot is not a failure.
  - **The library index was saved through a bare `try?` and read strictly.**
    Two independent causes could empty the shelf after a restart: `persist()`
    swallowed every write refusal silently (this container has refused
    container writes since 0.3.2), and a file that failed to decode — what
    happens the first time a build adds a field to a persisted struct and then
    loads the older file — was ignored and then overwritten by the next save.
    Fix: writes go to a write-tested storage root (Documents when it accepts
    writes; Library and tmp are probed) and to a Keychain mirror, every
    refusal is logged with its raw error, an unreadable file is copied aside
    instead of replaced, and every persisted struct (`InstalledGame`,
    `GameSettings`, the downloads list, the Steam caches) now decodes missing
    fields to defaults — so this upgrade itself can no longer wipe anything.
  - **"Downloading too quick — it said downloading but it wasn't."**
    Re-installs verify the chunks already on disk and fetch only what is
    missing, so a Steam install can legitimately finish in seconds — which
    read as fake. Fix: the progress line now says "checking files already on
    the device" whenever nothing is being fetched, the speed figure counts
    only actually-fetched bytes, and the install log records the real elapsed
    time. The download path itself is unchanged: the quick installs were real
    installs made of verifications.
  - **No cover art after install — because no art was ever requested.** The
    Steam install path built the library entry with `coverArtPath: nil`. Fix:
    installs fetch the cover (`library_600x900.jpg`) and header art from
    Steam's own CDN, save them at the storage root, and the shelf shows them;
    a refusal falls back to the generated tile and says so in the log.
- **The game settings sheet grew controls that actually apply (0.3.5, device
  verification pending).** The owner asked for a lot more settings control.
  Every new row names its mechanism: frame pacing (display maximum / 60 / 40 /
  30 / uncapped) goes through the engine's own `madeira_set_vsync_locked` call
  at session start and again at the first frame — resolved with `dlsym`, and
  if a build does not export the symbol the log says the choice stayed stored;
  sync engine (`MADEIRA_FASTSYNC`), AVX (`MADEIRA_FEX_AVX`),
  reduced-precision x87 (`FEX_X87REDUCEDPRECISION`), CPU count
  (`MADEIRA_CPU_COUNT`), DirectInput pad (`MADEIRA_DINPUT_PAD`), anisotropic
  limit (`DXMT_D9_ANISO_LIMIT`), game windows (`MADEIRA_GAME_WINDOWS`),
  launcher child-process wait (`MADEIRA_WAIT_CHILDREN`) and virtual display
  mode (`MADEIRA_VIRTUAL_MODE_SET`) are written as exactly the variables the
  pinned forks read, each set *or* unset per launch; launch arguments,
  working folder and a KEY=value environment editor pass through unchanged.
  The present/queue mode, MetalFX and the backend choice remain **stored
  only** and are labeled amber in the sheet — this build has no engine switch
  for them.
- **The owner's 0.3.5 run: Epic sign-in confirmed, Play refused at the
  storage gate — 0.4.0 moves the whole environment instead of asking
  `Documents` (2026-10-18, device verification pending).** The refusal itself
  was the honest half: the launch gate found the prefix unwritable and named
  it (this container has refused `Documents` writes at policy level since
  0.3.2 — see that entry). The dishonest half was the design: every build up
  to 0.3.5 hard-coded the Wine prefix at `Documents/windoz-prefix`, so on a
  container that refuses `Documents` no game could start no matter what the
  message said. Fix, in `AppContainer`: the storage root is now
  **negotiated** at first need — each candidate is probed with a real
  create + replace + delete through both Foundation and the C library
  (Documents, the app's Imported folder, Library, the system and shared
  locations the app can genuinely write), the first pass wins, and the
  choice is remembered in a mode-0600 `windoz-storage.json`; the prefix
  follows it (`<storage root>/windoz-prefix`), an existing
  `Documents/windoz-prefix` is migrated as one unit when the root moved, and
  every later write — downloads, art, mirrors, the Steam library — goes
  through the same negotiated root. The refusal message now carries the raw
  errno and the free-space figure of the failing path. Device confirmation
  pending.
- **Doz Dock — the actual dock — is ported (0.4.0, device verification
  pending).** The owner asked for Madeira's Dock inside Windoz and for a full
  Steam launcher launch. The contract is ported exactly from the pinned tree
  (`work/madeira-pinned/app/Madeira/MadeiraDock.swift`): the dock host
  (`dockhost.exe`, bundled by the engine since 0.3.5) is bridged into the
  prefix's `system32`; a per-launch handoff file (`windoz-dock/launch.auth`,
  `0600`, `O_CREAT|O_EXCL|O_NOFOLLOW`, App Support first with the negotiated
  storage root as fallback) carries the envelope (`MDOCK001` + Steam ID +
  App ID + name + refresh token); the environment the host reads
  (`MADEIRA_DOCK_SESSION=1`, `MADEIRA_DOCK_AUTH_FILE=\\?\unix…`, the
  `MADEIRA_STEAM_HOST_*` set) is applied per launch and cleared after; and
  the host's own report (`[steam-host]` rounds at
  `<prefix>/drive_c/madeira-dock.txt`) is parsed against an allow-list and
  turned into plain English — results 30/34/35/50/51/52, 37/49 with the CEG
  result, 45/48 with the client error, refusals 5–35. Offline is **Valve's
  own offline mode**, requested with `MADEIRA_DOCK_OFFLINE=1` when the
  per-game toggle is on or the path monitor reports no network — never
  faked. The per-game setting (Direct / Doz Dock / Steam desktop) validates
  before it launches: bundled dock host, a Steam sign-in Windoz can read,
  the Steam client components present, and the game's own
  `appmanifest_<appid>.acf` inside the **active** prefix — otherwise a named
  refusal, not a hang. The handoff file is deleted after every session, and
  Steam desktop runs the full client in a virtual desktop for manual
  sign-in and library use — no game auto-started.
- **Steam client components install from Valve's own CDN, pinned (0.4.0).**
  Doz Dock and Steam desktop need the Steam client's own Windows files
  inside the prefix, and until 0.4.0 the app assumed they would appear. The
  game's settings sheet now offers the download: three packages from
  `client-update.akamai.steamstatic.com`, SHA-256-pinned in
  `SteamClientRuntime.swift` with sizes checked on arrival, unpacked into
  `Program Files (x86)/Steam` in the active prefix with Steam's registry
  keys and redirects written, staged through the negotiated storage root
  (this container refuses even `tmp`). "Prepared" means `steam.exe` and
  `steamclient64.dll` both exist — checked, not assumed.
- **Epic gains chunked downloads (0.4.0, device verification pending).** The
  owner asked for Epic downloads; the endpoints were the blocker — they are
  scoped to Epic's launcher client, which 0.3.4's launcher-scoped sign-in
  answers. The path is ported from **Legendary** (GPL-3.0; the binary
  build-manifest layout, the chunk container format, the CDN path scheme
  `{ChunksVx}/{group}/{hash}_{guid}.chunk`) and runs the owner's own
  session: the live Windows build's manifest URL comes from
  launcher-public-service (v2 by app name, falling back to the v1 list), the
  manifest is decompressed and SHA-1-checked, every chunk is fetched from
  Epic's CDN and accepted **only** when its decompressed bytes match the
  SHA-1 the manifest carries, files are assembled at their own part offsets
  and whole-file hashes verified where present, and the game lands under
  `<storage root>/EpicGames/<title>` with its program taken from the
  manifest's own launch executable, registered in the library with art.
  Named refusals, not guesses: encrypted manifests and encrypted chunks are
  refused (that is Epic's content protection — Windoz does not touch it),
  legacy JSON manifests are refused by name, paths that would escape the
  install folder are refused, and case-only filename collisions are refused
  with the reason. Updates, repair and resume are the next round.
- **The 0.4.0 fit-and-finish the owner asked for.** Cover art: the Steam
  install path fetched art since 0.3.5, but entries installed **before** that
  stayed blank — the game page now backfills an entry's cover/header from
  Steam's CDN the first time it is opened without them, once per session,
  logged. The achievements summary card moved **directly below the Play
  button** (earned/total plus the nearest few unlocks; the full list stays in
  the Achievements tab). Settings gained the **Steam launch** card: the
  per-game mode picker (Direct / Doz Dock / Steam desktop), the **offline
  mode** toggle (applied as Valve's own offline request when Doz Dock runs
  the game), the components status row and its install button. The launch
  screen states the mode it used, and Direct mode says plainly when a title
  will need Doz Dock instead.
- **0.5.0 — the six-phase owner round (2026-10-18).** Built on 0.4.0 as one
  commit per phase on `ci-050` (1/6 … 6/6), each phase gated by
  `typecheck.yml` (phase gates #22–#29 — three runs caught real mistakes
  before their fixes; 6/6's runs are the first that also build and run the
  host tests). Full detail per phase in
  `docs/CHANGES.md`. What was asked, what the root causes were, and what is
  still unverified:
  - **1/6 idle heat** — several small always-running things, all bounded now:
    cover art decodes off the main thread behind a cache, the engine log
    publishes at ≤10 Hz, Home's dates are static text, the Steam CM socket
    closes the moment a refresh finishes with no download, and the launch
    watchdog stops after its one warning. A DEBUG-only idle monitor logs
    CPU/threads/thermal every 30 s so "it's warm" has numbers.
  - **2/6 the tap bug** — a second tap during the push animation stacked a
    second game page, and a stray controller Select could re-point
    navigation at a different game. The shelf now ignores input while a game
    page is up; Back leaves the page.
  - **3/6 launch pipeline** — nine named steps (JIT, prefix, program, storage,
    launch mode, screen, service + translator, process, first frame) with live
    detail, elapsed time and Cancel on the start screen; a failure keeps its
    steps, the real error, a suggested fix, the log tail and Retry on the
    game page. One on-disk log (`windoz-logs/windoz.log`) gains the engine's
    `madeira-log.txt` tail at session end; UI publishes stay coalesced at
    10 Hz.
  - **4/6 built-in JIT** — `WindozJITHelper.appex` (bundle id
    `com.milifrr.windoz.jit-helper`, built on vendored StikJIT — MPL-2.0,
    notices added) attaches to the engine by PID; pairing data lives in the
    Keychain; setup detects and names exactly what is missing (pairing file,
    LocalDevVPN, DeveloperDiskImage); StikDebug stays as the fallback. The
    helper **cannot** run under LiveContainer — the app detects that, says
    so, and falls back instead of pretending. Madeira's JIT shortcut over the
    network was not ported. Unverified on device until the owner runs the
    standalone sideload.
  - **5/6 runtime auto-install** — Wine Mono (pinned 11.0.0 from WineHQ,
    SHA-256 strict), VC++ 2005–2022, .NET, DX June 2010 and the game's own
    `_CommonRedist`, offered when a session needs them — never at idle app
    start. Vendor URLs only, no Microsoft binary in this repo; per-prefix
    ledger (`<prefix>/windoz-runtimes.json`); unpinned vendor-servicing links
    freeze their first download's SHA-256 and a later change is **refused**
    until the explicit "Accept the vendor's new file" in Settings. Downloads
    retry with backoff, cancel and resume, and cached files are reused.
    Installers run as real Windows sessions through the launch pipeline, one
    per app run; whether one actually stuck is verified by probe files the
    next time a game page opens — attempt, not assumption. Named refusals
    where something cannot work: 32-bit installers (no i386 support), .NET
    Desktop 4.8 and DX June 2010 (unavailable in this build, with the
    reason), Steam client components (existing Doz Dock flow).
  - **6/6 Epic downloads, root-caused against Legendary.** (a) Chunk URLs
    were built from the manifest URL *with its signed query string* —
    `URL.deletingLastPathComponent()` keeps the query — so every chunk
    address was a request for the CDN *directory*, answered 404 within a
    second: the owner's "downloads fail instantly". (b) The manifest and
    chunk fetches sent `Authorization: bearer …`, but Legendary fetches both
    unauthenticated — the signed query string is the authorization
    (`core.py get_cdn_manifest`). Also: the assets response parses leniently
    now (a strict decode could silently empty the list, and the UI then said
    "no live Windows build", which was not true); the launcher service's
    manifest SHA-1 is verified over the raw bytes; the loop pauses between
    chunks, resumes where it stopped, cancels on request, removes the
    in-progress file on any failure, and skips finished files whose manifest
    hash matches, so cancel + restart does not re-download. Every stage logs
    through `[epic-dl]` with query values redacted and no tokens anywhere.
    The protocol is `EpicProtocol.swift` (Foundation + CryptoKit + zlib only)
    and CI builds and runs `tests/host/epic-protocol-tests.swift` with a
    mocked transport — the query-string and lenient-parse bugs are locked in
    as regressions. Encrypted manifests/chunks are still refused by design,
    with the reason named. Unverified on device until the owner retests.
  - **Owner device checklist** (the only proof that counts): leave the app
    open 10 minutes (should stay hand-temperature); tap a game twice fast
    (exactly one page); start the test game (watch the nine steps; pull
    `windoz-logs/windoz.log` if it stalls); on a standalone sideload open
    Settings > JIT and follow the pairing steps, then confirm the JIT step
    goes green at launch; open a game with a missing runtime (the card lists
    it — install Wine Mono first); Epic > Download (watch `[epic-dl]` — a
    failure now names its stage and HTTP status instead of dying in one
    second).
- **Owner round for 0.6.0 (LiveContainer, 2026-10-18 — build 0.5.0):** five
  findings, each root-caused and fixed; every fix is device-verification
  pending.
  - **(1) "Whenever I launch a game it freezes in the launch screen."**
    Three compounding faults in `WindozEngine`'s launch path: the stall
    watchdog was scheduled with `Timer.scheduledTimer` from the launch body,
    which runs off the main actor — a dispatch-worker thread never runs a run
    loop, so the 180 s budget that should have turned a stall into an honest
    failure **could not fire**; the guest-start continuation had no exit
    while the CPU translator waited on the debugger's JIT script (the
    engine's init lock held); and every UI state write in `launch` (phase,
    session game, steps, failure card) was off the main actor, so SwiftUI's
    updates were a coin toss. Now: the watchdog starts on the main thread; a
    **160 s guest-start budget** with an exactly-one-resume guard turns the
    stall into a named failure with the failing stage's own words; the run is
    **marked spent** (`engineWedged`) so a later Play refuses by name instead
    of wedging again; the Windows service process is stopped; and a
    translator that answers *late* cannot start a guest behind the app's back
    (`sessionAbandoned` checks).
  - **(2) "I can't restart the app from LiveContainer for a bit."** The same
    wedge: nothing released the engine or the process slot. With the teardown
    above plus **Quit Windoz** (failed-launch card, game page, session menu,
    Settings → Advanced — flush the log, then exit on purpose), LiveContainer
    gets its slot back immediately instead of after a system kill.
  - **(3) "Game download not showing up in the downloads tab."** Steam
    installs (Windoz's depot downloader) and Epic's chunked installer keep
    their progress in their own store objects; the tab only read
    `DownloadManager`, which game installs never touch. The tab now shows one
    section per live source with the same controls each store sheet offers,
    plus a live count badge.
  - **(4) "Phone still getting hot."** The wedged service process burning CPU
    during a frozen launch (fixed above), plus the on-disk log sink writing
    one dispatch + one syscall per line while a chatty boot logs thousands
    per second — now batched (0.5 s / 256 KB, tails flush first). The audit
    of every repeating source (timers, monitors, loops) found no idle
    repeater: watchdog and session timers are launch/session-scoped, the idle
    monitor is DEBUG-only and passive, Steam disconnects after 60 s idle, and
    every animation is value-driven.
  - **(5) "Stuff is too big, looks like iPadOS UI for iPhone."** One fixed
    "10-foot" scale everywhere (42 pt wordmark, 280×380 hero tiles in a 460 pt
    rail, 240 pt banner, fixed 200 pt covers, 18-20 pt padding). Redesigned
    phone-first around new `Metrics`: 30 pt wordmark, 176×238 hero tiles in a
    330 pt rail, 112×150 shelf tiles, 3:4 adaptive library grid, 200 pt
    banner, 16 pt rhythm everywhere, real sheet detents with drag handles.
  - **0.6.0 device checklist** (the proof that counts): launch the test game
    and let it run — a stall must become a named failure with a Quit button
    (≤160 s), never a frozen screen; if it stalls, tap **Quit Windoz**,
    reopen from LiveContainer immediately (no waiting) and launch again — it
    must start or refuse with the wedge message, not hang; install a
    Steam/Epic game and watch it appear in Downloads with the tab badge;
    leave the app open on Home (it should stay hand-temperature); judge the
    new layout on the phone.
  - **Record:** typecheck gates #33 (`f2535ee`, the launch fix), #36 (the
    full tree, including the UI redesign) and #37 (`158f669`, the 0.6.0
    bump) are green. The full pipeline then did exactly what the new gate
    exists for: **run #18 failed inside the gate** — the app bundle still
    claimed 0.5.0 build 5 because its Info.plist values were hardcoded in
    `project.yml` while the helper's already referenced the build settings;
    nothing broken was ever published. `963cb1a` made the build settings the
    single source (gate #38 green). **Run #19 failed on the step's own
    version extraction** — an unanchored grep caught a comment that mentions
    MARKETING_VERSION — while the IPA itself was already fully correct;
    `4f51018` replaced the extraction with the tested
    `scripts/read-version.py`. **Run #20 is green end to end**: the IPA check
    passed inside the workflow and `release-ipa.yml` published the artifact
    automatically as the GitHub Release
    [`v0.6.0`](https://github.com/MiliFRR/windoz/releases/tag/v0.6.0) —
    `windoz-0.6.0-build6.ipa`, 78,293,503 bytes, SHA-256
    `4BB881B58149CA4C07306EA62A9D4BE1B499F584395D201482AC1DFB90653EA6`;
    the same file is kept locally as `windoz-ipa-keep/windoz-17.ipa` and
    re-checked with `scripts/check-ipa.py --require 0.6.0`.
- **Owner round for 0.7.0 (LiveContainer, 2026-10-19 — build 0.6.0):** the
  owner's report was that nothing had changed, with one instruction: use
  Madeira's engine for playing games and fix the UI. Both are answered;
  everything is device-verification pending.
  - **(1) "Just use Madeira's engine for playing the games."** 0.6.0 had only
    changed the failure handling around Windoz's own launch path. The path
    itself still called `fex_initialize()` from Swift (Madeira never does on a
    game launch) and **never allocated or published the JIT pool** the pinned
    Wine fork's `virtual_ios.c` needs (`WINE_IOS_JIT_RX/RW/SIZE`), so guest
    executable pages had nowhere to live — a black launch screen and a hot
    phone. New `JITPool.swift` ports Madeira's `StikJITHelper.allocatePool`
    (debugger BRK, hole census, placement rules, RW alias, no-footprint
    ledger); `WindozEngine.startGuestProcess` now runs Madeira's exact order:
    grant the pool → publish the variables → detach the debugger → start the
    Wine service → `wine_process_start`. A refused pool is a named failure
    with a Quit path, not a freeze; the launch checklist gained an
    "Executable memory is ready" step.
  - **(2) "Fix the UI."** The 0.6.0 rescue kept the console language (wordmark,
    hero carousel, glass cards, tracked uppercase labels, oversized tiles).
    It is now a normal iPhone app: system grouped backgrounds and cards,
    standard type and section headers, Home with compact Continue-playing /
    Recently-added shelves and a plain games list, a 3-column library grid,
    an 82×110 game header and standard Play button, standard List Settings
    and Setup. Dark mode is retained for the session overlays, but the
    backgrounds are system dark colours, not gradients.
  - **Record:** the `ci-070` gates were green (#39 and #40, superseded by later
    pushes on the same branch), and the final tree `b8b3fed` is green in
    **#43**. Merged to `main` as `7f5cf67`. `build-ipa.yml` **run #21**
    (2026-10-19) is green through the IPA gate, and `release-ipa.yml` run #4
    published [`v0.7.0`](https://github.com/MiliFRR/windoz/releases/tag/v0.7.0) —
    `windoz-0.7.0-build7.ipa`, 78,276,079 bytes, SHA-256
    `81ED949EFBCF016CD48B07E69E1F67C550F4004F9F8B026CFC14D6873621DF69`
    (kept locally as `windoz-ipa-keep/windoz-18.ipa`, re-checked with
    `scripts/check-ipa.py --require 0.7.0 --min-build 7`). The executable
    contains `[jit-pool]`, `WINE_IOS_JIT_RX`, `jit26_prepare_region` and
    `MADEIRA_DETACHED`, so the Madeira-pool launch path is in the shipped
    binary.
  - **0.7.0 device checklist** (the proof that counts): launch a game and watch
    the new "Executable memory is ready" step; the log must name the pool
    before the Wine service starts, and the game must reach its own window
    instead of the black launch screen. Judge Home, Library and the game page
    at arm's length: covers, titles and buttons should read like a normal
    iPhone app, not a television. If the pool step fails, the named message
    says whether no debugger was attached or the placement was refused; use
    Quit Windoz and reopen instead of waiting on a frozen screen.
- **Owner round for 0.8.0 (LiveContainer, 2026-10-19 — build 0.7.0):** the
  owner ran the 0.7.0 keeper, confirmed **direct launches work on device**,
  and asked for the next round: swap memory; Doz Dock fixes plus fuller Steam
  support; a settings icon during a game with control layouts and performance
  stats; and a more modern UI in the same direction as 0.7.0's redesign
  ("a step in the right place"). All answered; everything is
  device-verification pending.
  - **(1) Swap memory.** The pinned engine already has a file-backed guest
    memory tier and its iOS bridge already arms it — `wine_process_start`
    reads `swap-mb` from `Documents/madeira.cfg`, and at ≥ 64 MB recreates
    `NSTemporaryDirectory()/madeira-swap.bin` (`NSFileProtectionNone`) and
    exports `MADEIRA_SWAP_FILE` / `MADEIRA_SWAP_MB`. Windoz never wrote that
    file. New `Sources/Engine/MadeiraConfig.swift` + Settings → Memory: Off /
    1 GB / 2 GB / 4 GB (the same choices, units and default as Madeira's own
    page) plus the `env.MADEIRA_SWAP_COVERAGE` picker (classic default;
    blocks / wide / broad). The writer merges — comments and foreign keys stay
    byte-for-byte, atomic write, read-back verified — and the launch log names
    the tier it found. Takes effect on the next launch.
  - **(2) Doz Dock fixes.** Two code-level causes: (a) only Steam's canonical
    folder was searched, so a game installed into any other
    `libraryfolders.vdf` library failed validation with "install record not
    found" — `DozDock` now lists **every library the client knows**, resolves
    each manifest against its own library, unions depots, and keeps the same
    caps and path-safety rules; (b) a slow client start read as a stall — the
    session HUD now polls `C:\madeira-dock.txt` every 0.5 s and shows the live
    stage (handoff → connection → offline logon → updates → launch) as a chip,
    with refusals in plain words. No device log of the owner's failed run
    exists; these are code-level fixes, marked as such.
  - **(3) Full Steam support.** **Open Steam** starts Valve's client as a
    session (`.steamDesktop`) signed in with the stored token; **Add installed
    games** (`Sources/Steam/Content/SteamClientLibrary.swift`) scans every
    library in the prefix for what the client installed, adds/completes
    entries (defaulting to Doz Dock mode) and fetches missing art; the Steam
    sheet's client card reports readiness, installs components with live stage
    text, then offers both actions.
  - **(4) In-session settings, layouts, stats.** The session HUD gear opens a
    menu (raw UIKit, drawn above the host): **Controls** — Keyboard & mouse
    (default; the physical pad is translated to WASD + mouse + template keys
    and the game is never told a controller exists), Xbox, or PlayStation 5
    (on-screen pad + physical pad merge into one XInput snapshot published to
    slot 0; PS5 = the same pad with DualSense glyphs, stated honestly) —
    stored per game, changeable mid-session, also pickable on the game page;
    **Performance stats** — one persisted toggle; overlay shows FPS,
    1 %/0.1 % lows (percentiles of the last minute of the engine's presented
    frames), RAM (physical footprint), CPU (thread times, ported CPUMeter) and
    battery (level + session delta). Every number is measured on device.
  - **(5) UI modern pass.** Same compact native direction: one accent→indigo
    gradient for primary actions only (Play, the featured card's control);
    Home opens with a full-width featured card (most recent game, hero art,
    one play affordance) and the shelf becomes "Recently played"; Library
    gains system search and All/Imported/Steam/Epic filter chips; the game
    page's Controls section is the new layout picker (the old custom
    touch-overlay editor stored layouts the session never read — its stale
    note said so — and is replaced).
  - **Record:** the round was built on `ci-080`; the typecheck gate, the
    `build-ipa.yml` run and the release/keeper are recorded here when they
    complete.
  - **0.8.0 device checklist** (the proof that counts): set a swap size in
    Settings → Memory (or leave it off), then launch a game and confirm the
    log line naming the tier; on a Doz Dock launch, the session chip must
    advance through the stages (or turn into plain words on failure); **Open
    Steam** must reach Valve's client window; **Add installed games** must
    list what the client installed; the ⚙ menu must switch layouts live and
    the overlay must show FPS / 1 % / 0.1 % / RAM / CPU / battery.
- Later failures will be recorded here as they are diagnosed and fixed.

## JIT

What this build (0.7.0) actually offers, in order of what works:

- **The bundled helper extension** — added in 0.5.0. `WindozJITHelper.appex`
  (bundle id `com.milifrr.windoz.jit-helper`) runs inside the app and attaches
  to the engine process by PID, built on the vendored StikJIT (MPL-2.0 —
  notice in `THIRD-PARTY-NOTICES.md`). It needs the device's **pairing file**
  (imported into the Keychain once), **LocalDevVPN** (App Store — Windoz opens
  `localdevvpn://enable?scheme=windoz` and LocalDevVPN returns through
  `windoz://…`), and a DeveloperDiskImage. Settings and the first-run screen
  check each of those and say exactly which one is missing.
- **StikDebug** (a separate app) stays as the fallback, and it is the only
  route inside **LiveContainer** — a guest app cannot start a nested
  extension. The app detects `LC_HOME_PATH`, says so, and uses StikDebug
  instead of pretending the helper can work.
- A launch first **attempts the chosen method automatically** (JIT method
  persisted under `windozJITMethod`); the launch pipeline's JIT step reports
  which route was used and what happened.
- Sideload with SideStore/AltStore/Sideloadly; the bundle id is
  `com.milifrr.windoz`. The helper's ids derive from
  `WINDOZ_BUNDLE_IDENTIFIER`, so a re-signed bundle keeps working.
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
