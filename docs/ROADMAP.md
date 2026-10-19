# Windoz roadmap

Honest status. A checkbox is only ticked when the thing was observed working —
on a real device where device behaviour matters. Everything else is marked for
what it is.

## Legend

- ✅ **done** — exercised, and (where it can only be true on hardware) seen on a
  device.
- 🟡 **partial** — the real, testable part works; the rest is named below.
- ⛔ **not implemented** — the UI says so; nothing pretends otherwise.

## Engine

| Area | State | Notes |
|---|---|---|
| Prefix create / repair / delete | ✅ | `PrefixManager` → `madeira_seed_prefix_if_needed` |
| wineserver + FEX core | ✅ | `WindozEngine.startEngineCore` (Settings → Diagnostics) |
| Log streaming (FEX/JIT → in-app log) | ✅ | `EngineLogStream` |
| JIT probe + StikDebug deep link | ✅ | `JITManager`; re-checked every launch |
| Bundled JIT helper extension | ⛔ | no helper target yet, so the UI offers StikDebug only (the bundle is checked, not assumed) |
| Memory-entitlement report | ✅ | honest "not active" when the signing lacks it |
| **Game session host** (presentation, input, the guest process) | 🟡 | ported in 0.3.4: `launch` waits for the presenting layer, then starts wineserver → FEX → `wine_process_start`; the session ends on the guest process's exit. 0.3.5 adds stage-by-stage status, its own startup queue, a storage preflight and a watchdog (a stalled launch ends with a named stage). Device verification pending (the 0.7.0 direct-launch path is device-confirmed). Limits: one session per app run; input is touch (aspect-fit 1:1), a hardware keyboard, the on-screen key row, and since 0.8.0 the three control layouts (Keyboard & mouse / Xbox / PlayStation 5) |
| **Swap tier** (the engine's file-backed guest memory) | 🟡 | 0.8.0: Settings → Memory writes `Documents/madeira.cfg` (`swap-mb`, `env.MADEIRA_SWAP_COVERAGE`) with merge semantics and read-back verify; `wine_process_start` arms the tier at ≥ 64 MB. Device verification pending |
| **Launch modes** (Direct / Doz Dock / Steam desktop) | 🟡 | ported in 0.4.0 from Madeira's dock contract: per-game mode, the handoff file, the `MADEIRA_STEAM_HOST_*` environment, the report read back and translated, Valve's own offline mode behind a toggle (`MADEIRA_DOCK_OFFLINE=1`), and named refusals when the dock host, a Steam sign-in, the client components or the game's `appmanifest` are missing. 0.8.0: every Steam library the client knows is searched, the session HUD shows the dock's live stage, and the client itself can be started (Open Steam). Device verification pending |
| **Storage negotiation** (the root that accepts writes) | 🟡 | `AppContainer.probeWrites` probes each candidate with a real create + replace + delete through Foundation and the C library, remembers the winner (`windoz-storage.json`), and the prefix + downloads + Steam library follow it. Answers the device's `Documents` write refusal; device verification pending |
| Per-game settings → engine | 🟡 | applied: the launch environment (arguments, working folder, screen scale, custom switches), frame pacing through the engine's own `madeira_set_vsync_locked` call, and nine per-launch engine variables (sync engine, AVX, x87, CPU count, DirectInput pad, anisotropic limit, game windows, child-process wait, virtual display mode). Stored only, labeled as such: the present/queue mode, MetalFX and the backend choice |
| Native D3D12 path | 🟡 | experimental in the engine; selectable per game, not yet applied |

See `docs/ENGINE.md` for the boundary and the D3D12 detail.

## Stores

| Store | State | Notes |
|---|---|---|
| Local games ("Add local game") | ✅ | import from Files; anti-cheat scan; runs into the library |
| GOG | 🟡 | DRM-free: import the installed files; no Galaxy client needed |
| Steam | 🟡 | native sign-in (Guard code / in-app approval / QR), owned library, depot downloads with journaled resume + per-chunk SHA-1 verify; installing adds the game to My games (with cover/header art from Steam's own CDN since 0.3.5, backfilled for older entries in 0.4.0), where the session host (0.3.4) can start it. 0.4.0 adds the per-game launch modes (Direct / Doz Dock / Steam desktop), the Steam client components installer from Valve's pinned CDN, and the offline toggle (Valve's own offline mode). The game page reads achievements (summary under Play since 0.4.0) and friends from Steam. 0.8.0 adds full client use: **Open Steam** starts Valve's client as a session, **Add installed games** imports what the client installed (any library), and the dock searches every library the client knows. Device verification of install + launch + dock pending |
| Epic | 🟡 | device-code sign-in (approved on Epic's own site) plus the launcher-scoped sign-in its library service requires, owned library with real art, and chunked downloads in 0.4.0 (Legendary-ported binary manifest + hash-verified chunks, landing in `EpicGames/<title>` and registering with art). Updates/repair/resume are the next round; device verification pending |
| Rockstar, EA, GOG | ⛔ | official launcher in Wine; needs the launcher pipeline (the session host exists in 0.3.4; the pipeline that installs and wraps a launcher does not) |

Credentials live in the Keychain (`Keychain.swift`); tokens are never logged.

## Downloads

| Feature | State |
|---|---|
| Queue, pause/resume, cancel | ✅ real `URLSessionDownloadTask` + `resumeData` |
| SHA-256 verification | ✅ |
| Free-space check before queueing | ✅ |
| Wi-Fi-only rule | ✅ (`NWPathMonitor`) |
| Persisted queue across relaunch | ✅ |
| `BGProcessingTask` continuation | 🟡 registered only when the live bundle id is in the build's `BGTaskSchedulerPermittedIdentifiers`; otherwise a log line says so |
| Live Activity / Dynamic Island | 🟡 activity is requested; **rendering** needs the paired widget extension (below) |

## UI

| Feature | State |
|---|---|
| Console shell (Home / Library / Downloads / Settings) | ✅ |
| Home: featured card, Recently played / Recently added shelves, games list | ✅ | featured card since 0.8.0 (hero art + one play affordance) |
| Library: search, filter chips (All / Imported / Steam / Epic), grid | ✅ | search + chips since 0.8.0 |
| Game page (hero, Play, tabs: Overview / Achievements / Friends, gear settings sheet) | ✅ |
| First-run setup wizard (JIT, memory, storage, runtimes) | ✅ |
| Controller navigation + focus model | ✅ |
| Touch-overlay editor (per-game, saveable) | 🟡 replaced in 0.8.0: the game page's Controls section is the new layout picker (Keyboard & mouse / Xbox / PlayStation 5, read by the session; changeable in-session). The old editor's custom layouts were never read by the session — its own note said so — and its file is retired |
| In-session settings menu (⚙) | ✅ by construction: control layout (three defaults) and the performance-stats toggle, drawn above the host |
| Performance overlay (FPS, 1 % / 0.1 % lows, RAM, CPU, battery) | ✅ by construction: sampled at 4 Hz on device; the toggle is persisted |
| One accent gradient for primary actions; Home featured card; Library search + filter chips | ✅ by construction (0.8.0 modern pass, same compact direction) |
| 120 Hz / Dynamic Type / VoiceOver / Reduce Motion | 🟡 honoured where applicable |
| Liquid Glass (`glassEffect`) | ⛔ v1 uses `.ultraThinMaterial` to keep the build safe |

## LiveContainer

| Requirement | State |
|---|---|
| Detect LiveContainer (`LC_HOME_PATH`) | ✅ |
| Route JIT through StikDebug where the helper cannot run (LiveContainer) | ✅ |
| Bundled JIT helper (`WindozJITHelper.appex`) attaching by PID | 🟡 built in 0.5.0; standalone-sideload verification pending |
| Read the bundle id from `Bundle.main` (re-sign safe) | ✅ |
| Re-sign-safe background-task identifier | 🟡 derived from the live bundle id; when it is not among the app's permitted identifiers the task is not registered and a log line says why |
| Increased-memory entitlement | ⛔ not grantable via LiveContainer; reported as unavailable |

## Next, in order

1. **Device-verify 0.8.0** — swap memory (Settings → Memory writes
   `Documents/madeira.cfg`; the launch log names the tier), Doz Dock on any
   library with a live stage chip in the session, Open Steam + Add installed
   games, the in-session ⚙ menu (three layouts, live switching) and the
   performance overlay (FPS / 1 % / 0.1 % / RAM / CPU / battery), and the
   modern pass (featured card, search + chips, gradient primary actions).
   0.7.0's direct launch is device-confirmed; the rest of the older checklist
   (storage negotiation, an Epic download end to end, the JIT helper on a
   standalone sideload) stays on the same list. The owner's run is what
   confirms them.
2. **Epic updates / repair** against the live manifest, and
   install-tag selection (resume landed in 0.5.0).
3. **Launcher-in-Wine pipeline** for GOG, Rockstar and EA (the Steam dock is
   ported; the wrapper machinery for the other stores is not).
4. **Widget extension** for the Live Activity / Dynamic Island rendering.
5. **The remaining stored settings** — the present/queue mode and MetalFX have
   no engine switch in this build; the backend choice stays informational.
   A software keyboard for the session.
6. **Online / networking** work inside Wine (DNS, TLS, store auth) — tested on a
   real device before any claim is made.

Anti-cheat remains an **awareness** layer only (`AntiCheatDetector`): it reports
what a game ships with and what that means here; it never tries to bypass
anything.
