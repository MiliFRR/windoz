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
| Memory-entitlement report | ✅ | honest "not active" when the signing lacks it |
| **Game session host** (JIT pool, CAMetalLayer, input) | ⛔ | `launch` throws `sessionHostingNotImplemented` after a real preflight |
| Per-game settings → engine | 🟡 | stored and validated; applied by the (unported) session host |
| Native D3D12 path | 🟡 | experimental in the engine; selectable per game, not yet applied |

See `docs/ENGINE.md` for the boundary and the D3D12 detail.

## Stores

| Store | State | Notes |
|---|---|---|
| Local games ("Add local game") | ✅ | import from Files; anti-cheat scan; runs into the library |
| GOG | 🟡 | DRM-free: import the installed files; no Galaxy client needed |
| Steam | ⛔ | native sign-in / library / depot downloader not written yet |
| Epic | ⛔ | native sign-in / chunked downloads not written yet |
| Rockstar, EA | ⛔ | official launcher in Wine; needs the session host |

Credentials live in the Keychain (`Keychain.swift`); tokens are never logged.

## Downloads

| Feature | State |
|---|---|
| Queue, pause/resume, cancel | ✅ real `URLSessionDownloadTask` + `resumeData` |
| SHA-256 verification | ✅ |
| Free-space check before queueing | ✅ |
| Wi-Fi-only rule | ✅ (`NWPathMonitor`) |
| Persisted queue across relaunch | ✅ |
| `BGProcessingTask` continuation | 🟡 submitted; identifier must match the **live** bundle id after a re-sign |
| Live Activity / Dynamic Island | 🟡 activity is requested; **rendering** needs the paired widget extension (below) |

## UI

| Feature | State |
|---|---|
| Console shell (Home / Library / Downloads / Settings) | ✅ |
| Cover carousel, Continue Playing, Recently Added | ✅ |
| Game page (hero, Play, playtime, compatibility, anti-cheat badge) | ✅ |
| First-run setup wizard (JIT, memory, storage, runtimes) | ✅ |
| Controller navigation + focus model | ✅ |
| Touch-overlay editor (per-game, saveable) | ✅ layout editing; renders in-session once the host is ported |
| 120 Hz / Dynamic Type / VoiceOver / Reduce Motion | 🟡 honoured where applicable |
| Liquid Glass (`glassEffect`) | ⛔ v1 uses `.ultraThinMaterial` to keep the build safe |

## LiveContainer

| Requirement | State |
|---|---|
| Detect LiveContainer (`LC_HOME_PATH`) | ✅ |
| Route JIT through StikDebug (no bundled helper) | ✅ |
| Read the bundle id from `Bundle.main` (re-sign safe) | ✅ |
| Re-sign-safe background-task identifier | 🟡 derived from the live bundle id; a mismatch fails silently and is documented |
| Increased-memory entitlement | ⛔ not grantable via LiveContainer; reported as unavailable |

## Next, in order

1. **Port the session host** (JIT pool + Metal presentation + input routing)
   behind `WindozEngine`, so `launch` runs a game instead of throwing. Then the
   per-game settings actually take effect.
2. **Widget extension** for the Live Activity / Dynamic Island rendering.
3. **Steam native sign-in** (password + Steam Guard, QR), then the owned
   library, then the depot downloader.
4. **Epic native sign-in** and chunked downloads; launcher-in-Wine for the
   stores without a usable API.
5. **Online / networking** work inside Wine (DNS, TLS, store auth) — tested on a
   real device before any claim is made.

Anti-cheat remains an **awareness** layer only (`AntiCheatDetector`): it reports
what a game ships with and what that means here; it never tries to bypass
anything.
