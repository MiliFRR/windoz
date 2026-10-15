# windoz

A Windows game launcher and runner for iPhone. Sign in to Steam, browse your
library in a console-style UI, download games in the background, and run them
locally — unmodified — on a jailed iPhone (iOS 26+, sideloaded only).

**Status: Phase 0 (reproducible CI build) — scaffold pushed, first CI run
starting.**

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

- [ ] **Phase 0 — Reproducible build.** CI produces an installable IPA from a
  clean clone. This also discharges the LGPL clean-rebuild obligation
  Madeira marks UNVERIFIED. **In progress.**
- [ ] **Phase 1 — Runtime.** Launch a simple 64-bit game from a local
  folder; Settings shows JIT + Memory+ status; launch blocked with a clear
  message when not ready.
- [ ] **Phase 2 — UI shell.** Console-style Library with mock data: cover-art
  carousel, focus/selection animation, ambient blur, dark theme.
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
- **Open watch-item:** nothing in the audited scripts creates the initial
  `app/Madeira/libdxmt_combined.a` (the DXMT script only refreshes it). If
  the Xcode app build fails on it, the merge step lives in the app project's
  build phases and will be handled then.
- **CI run #4 failed** at "Build LLVM for iOS" link: `FAILED:
  lib/LLVMHello.dylib` — `ld: unknown file type in '.../LLVMHello.def'`.
  LLVM's export-file logic uses `APPLE` in some places (true on iOS) and
  `CMAKE_SYSTEM_NAME MATCHES "Darwin"` in others (false on iOS); the module
  branch emitted a Windows `.def` file to Apple's linker. Every LLVM *tool*
  linked fine at this point. Fixed: `-DLLVM_ENABLE_PLUGINS=OFF` (no loadable
  modules are needed; DXMT links LLVM statically). Also fixed the Wine
  `dlls/dwrite` header build to use Madeira's own `make -C <dir>` pattern.
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
| VC++ runtime DLLs | Microsoft redistributable terms | Never committed; fetched at build time from Microsoft |

Rules: keep the licence bundle and per-file headers; do not push AI-assisted
fork changes upstream to FEX-Emu (their policy); never add DRM-circumvention
code.
