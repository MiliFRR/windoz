# Doz Dock

Doz Dock is windoz's **background download and sync engine for game stores**
plus the piece that hands a Steam-DRM title to **Valve's own client** running
inside Wine when Direct launch cannot work. This document says exactly what
exists today, what the pieces are, and the rules the implementation must keep.

> **State, plainly (2026-10-18, build 0.4.0 — device verification pending):**
> the **Steam client is real** — native sign-in (password + Steam Guard, or a
> QR code), the owned library, headless depot downloads into the prefix
> (`Sources/Steam/`, wired by `Sources/Stores/SteamStore.swift`), and, new in
> 0.4.0, the **dock itself**: the per-game launch modes (Direct / **Doz
> Dock** / Steam desktop), Madeira's dock contract ported exactly, the Steam
> client's own Windows components installed from Valve's pinned CDN, and
> Valve's own offline mode behind a per-game toggle. **Epic is real through
> its downloads too** in 0.4.0 — device-code sign-in, the launcher-scoped
> sign-in its library service requires, the owned library with real art, and
> now chunked downloads from Epic's own CDN with every chunk SHA-1-verified
> (`Sources/Epic/EpicDownloader.swift`, ported from Legendary). The launcher
> stores (EA, Rockstar) still report plainly what they can and cannot do. The
> generic download engine (queue, pause/resume, SHA-256 verification,
> free-space checks, Wi-Fi-only rules, persistence across relaunch;
> `Sources/Downloads/`) stays in daily use for the Windows runtime files.
> Everything in this paragraph is code-complete and typechecked; the first
> device run that confirms it is the owner's next one.

## The two layers

Doz Dock has two layers, and they are deliberately separate:

### 1. Native store clients (headless, in Swift)

The goal: sign in once, see the owned library with real art, and download the
game's own files with no store client running. The approach is the proven one
from SteamKit2 / DepotDownloader (and Legendary for Epic) reimplemented in
Swift inside the app:

- **Steam — real** (ported from Madeira's pinned SwiftSteam client): password
  + Steam Guard sign-in (code or in-app approval) or a QR code, owned-library
  fetch, depot key/manifest auth and chunked downloads, Steam's own
  `appmanifest_<appid>.acf` layout, journaled resume and per-chunk SHA-1
  verification. Installs register in the library with cover/header art from
  Steam's own CDN. Device verification of the download path is pending.
- **Epic — real including downloads (0.4.0).** Device-code OAuth approved on
  Epic's own site plus the launcher-scoped sign-in the library service
  demands, the owned library with titles and art, and chunked downloads
  ported from **Legendary** (GPL-3.0; credit kept in the file header): the
  live Windows build's manifest URL from launcher-public-service, the binary
  build manifest (v18–v22+ layouts) decompressed and SHA-1-checked, every
  chunk accepted only when its decompressed bytes match the SHA-1 the
  manifest carries, files assembled at their part offsets and whole-file
  hashes verified where present. Installs land under
  `<storage root>/EpicGames/<title>` and register in the library with art.
  Encrypted manifests/chunks are refused by name (that is Epic's content
  protection — Windoz does not touch it); legacy JSON manifests are refused
  by name; updates/repair/resume are the next round.

Credentials live in the **Keychain**; tokens are never written to the
sandbox files, never logged, and never leave the device except to the store's
own endpoints. Files land through `AppContainer`, so they are where the user
can see them under Files and where LiveContainer's guest home puts them — and
since 0.4.0 that root is **negotiated** (a real write probe per candidate)
rather than hard-coded, so a container that refuses `Documents` still gets a
working environment.

### 2. Launcher pipelines (inside the Wine prefix)

Some titles need their store's launcher at runtime (Valve's own Steam client
for Steam-DRM titles; the EA App and the Rockstar Games Launcher for theirs).
Doz Dock runs the *real launcher* inside windoz's Wine prefix — wrapped so it
starts only when a title needs it, and closes when the game exits:

- **Steam — ported in 0.4.0** (the dock itself; contract below). The session
  host it needs landed in 0.3.4, and the Steam client's own Windows
  components install in the app from Valve's pinned CDN packages
  (`SteamClientRuntime.swift`: three zips, sizes + SHA-256 pinned, unpacked
  into the active prefix's `Program Files (x86)/Steam` with Steam's registry
  keys and redirects). "Prepared" means `steam.exe` and `steamclient64.dll`
  exist — checked, never assumed.
- a dedicated prefix per launcher stays the plan for EA/Rockstar, so an EA
  update cannot break Steam;
- small wrapper scripts that configure and launch the official installer,
  logged like everything else — **not implemented yet**; the launcher screens
  say so instead of offering a button that cannot work.

## The dock contract (ported exactly)

The source of truth is the pinned tree
(`work/madeira-pinned/app/Madeira/MadeiraDock.swift`); Windoz's port lives in
`app-windoz/Sources/Steam/Content/DozDock.swift` and keeps the wire format
byte-for-byte:

| Piece | Detail |
|---|---|
| Dock host | `C:\windows\system32\dockhost.exe` — the engine bundles it into the app; a build without it makes Doz Dock refuse with "the dock host was not built into this app" |
| Handoff file | `windoz-dock/launch.auth` (App Support first, the negotiated storage root as fallback), written `0600` with `O_CREAT\|O_EXCL\|O_NOFOLLOW`, deleted after every session |
| Envelope | `"MDOCK001"` + Steam ID (8 B LE) + App ID (4 B LE) + length-prefixed account name + refresh token |
| Environment | `MADEIRA_DOCK_SESSION=1`, `MADEIRA_DOCK_AUTH_FILE=\\?\unix…`, `MADEIRA_STEAM_HOST_APPID`, `_LAUNCH_OPTION`, `_CLIENT_DIR`, `_EXPECTED_INSTALL`, `_LOG`, and `_CEG` when the title ships CEG — all unset again when the session ends |
| Report | The host writes `[steam-host] <round> <field>=<value>` lines to `<prefix>/drive_c/madeira-dock.txt`; Windoz parses them against an allow-list of fields and rounds, then deletes the file |
| Failures | Result codes mapped to plain words: 30/34/35 / 50/51/52 (no connection / offline refused / offline lacks the game), 37 and 49 with the CEG result, 45 and 48 with the launch client error, refusals 5–35 |
| Offline | **Valve's own offline logon**, requested with `MADEIRA_DOCK_OFFLINE=1` when the per-game toggle is on or `NWPathMonitor` reports no network — never faked, never emulated |

Before a Doz Dock launch, Windoz validates and refuses by name when anything
is missing: the bundled dock host, a Steam sign-in it can read
(`SteamTokenStore`), the Steam client components, and the game's own
`appmanifest_<appid>.acf` inside the **active** prefix's `steamapps`. A game
installed by Windoz's own depot downloader lands exactly there (0.4.0 moved
the Steam library to follow the active prefix), so Valve's client sees it.
**Steam desktop** is the same components with no game auto-started: the full
client in a virtual desktop for manual sign-in and library browsing.

## What this will never do

- **No DRM circumvention.** Steam-DRM games run through *Valve's own client*
  running in Wine. The repository rule at the bottom of `README.md` applies:
  no DRM-circumvention code, ever.
- **No fake clients.** Doz Dock never impersonates the Steam client to a
  running game. Games that demand the client get the real one.
- **No unverified claims.** A checkbox in `docs/ROADMAP.md` is only ticked
  when a real download of a real title completed on a real device.

## Where it lives in the app today

| Piece | File | State |
|---|---|---|
| Download engine (queue/resume/verify) | `Sources/Downloads/DownloadManager.swift` | working, in daily use |
| Steam provider (sign-in, library, depots) | `Sources/Stores/SteamStore.swift` + `Sources/Steam/` | real: sign-in + owned library verified on device; depot downloads device-verification pending |
| Epic provider | `Sources/Stores/EpicStore.swift` + `Sources/Epic/` | real: both sign-ins verified on device; chunked downloads in 0.4.0, instant-failure root cause fixed in 0.5.0 (chunk URLs had carried the manifest's signed query string), off-device tests in `tests/host` — device verification pending |
| The dock itself | `Sources/Steam/Content/DozDock.swift` + `Sources/Engine/WindozEngine.swift` | ported in 0.4.0: modes, handoff, report, offline (device verification pending) |
| Steam client components | `Sources/Steam/Content/SteamClientRuntime.swift` | pinned Valve packages, checked "prepared" state |
| Store screens | `Sources/UI/` + Library → Stores | Steam and Epic open real sheets (install/progress); the rest show the stub state |
| Launcher pipelines (EA/Rockstar) | — | not implemented; the UI says so |
| Library, prefixes, paths | `Sources/Engine/`, `AppContainer.swift` | working; storage root negotiated since 0.4.0 |

## Roadmap for Doz Dock

Tracked in `docs/ROADMAP.md` (Phase 5 in `README.md`'s phase list); in order:

1. **Steam sign-in** — done and device-verified: password + Steam Guard (code
   or approval) and QR; tokens in the Keychain.
2. **Owned library** — done and device-verified: names, App IDs, art, in the
   Steam library sheet.
3. **Depots** — done: manifests, parallel chunked download, journaled
   resume, per-chunk SHA-1 verify, appmanifest record. Live Activity /
   background continuation still open.
4. **Launch hook + the dock** — done in 0.4.0: `WindozEngine` prepares the
   mode (Direct / Doz Dock / Steam desktop), writes the handoff, applies the
   host environment, reads the report back and answers in plain words; the
   Steam client components install from Valve's CDN. Device verification
   pending. Next: draw the report's offline/unlock states into the session
   screen so a slow first launch reads as progress, not a stall.
5. **Epic** — done in 0.4.0 through the downloads: device-code + launcher
   sign-ins, the owned library, and Legendary-ported chunked downloads with
   per-chunk verification and library registration. Device verification
   pending. Next: update/repair against the live manifest, download resume,
   and install-tag selection.
6. **Launcher pipelines** — the EA and Rockstar wrappers (and GOG's optional
   Galaxy) once the wrapper work lands; nothing exists for them yet and the
   UI says so.
