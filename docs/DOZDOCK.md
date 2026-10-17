# Doz Dock

Doz Dock is windoz's **background download and sync engine for game stores** —
the part of the app that owns getting a game from a store to the device without
a desktop machine in the middle. This document says exactly what exists today,
what the pieces are, and the rules the implementation must keep.

> **State, plainly (2026-10-17):** the **Steam client is real** — native
> sign-in (password + Steam Guard, or a QR code), the owned library, and
> headless depot downloads into the prefix (`Sources/Steam/`, wired by
> `Sources/Stores/SteamStore.swift`). Device verification of the download
> path is pending the owner's first run, and starting Steam games still needs
> the session host. **Epic now signs in too** — a device code approved on
> Epic's own website (no password ever typed into the app), then the owned
> library with real art (`Sources/Epic/`, `Sources/Stores/EpicStore.swift`);
> its chunked downloads are the next piece and the UI says so. The launcher
> stores (EA, Rockstar) still report plainly what they can and cannot do. The
> generic download engine (queue, pause/resume, SHA-256 verification,
> free-space checks, Wi-Fi-only rules, persistence across relaunch;
> `Sources/Downloads/`) stays in daily use for the Windows runtime files.

## The two layers

Doz Dock has two layers, and they are deliberately separate:

### 1. Native store clients (headless, in Swift)

The goal: sign in once, see the owned library with real art, and download the
game's own files with no store client running. The approach is the proven one
from SteamKit2 / DepotDownloader (and Legendary for Epic) reimplemented in
Swift inside the app:

- **Steam — implemented** (ported from Madeira's pinned SwiftSteam client):
  password + Steam Guard sign-in (code or in-app approval) or a QR code,
  owned-library fetch, then depot key/manifest auth and chunked downloads,
  with Steam's own `appmanifest_<appid>.acf` layout. First device
  verification pending.
- **Epic — sign-in and library done** (device-code OAuth approved on Epic's
  own site; the owned library with titles and art). Depot manifests and
  chunked downloads are the next piece: the launcher/CDN endpoints are scoped
  to Epic's launcher client and refused the device-flow session during
  development, so that round starts by settling the second, launcher-scoped
  authorization.

Credentials live in the **Keychain**; tokens are never written to the
sandbox files, never logged, and never leave the device except to the store's
own endpoints. Files land through `AppContainer`, so they are where the user
can see them under Files and where LiveContainer's guest home puts them.

### 2. Launcher pipelines (inside the Wine prefix)

Some titles need their store's launcher at runtime (Valve's own Steam client
for Steam-DRM titles; the EA App and the Rockstar Games Launcher for theirs).
Doz Dock's plan for those is *running the real launcher* inside windoz's Wine
prefix — wrapped so it starts only when a title needs it, and closes when the
game exits:

- a dedicated prefix per launcher, so an EA update cannot break Steam;
- small wrapper scripts that configure and launch the official installer,
  logged like everything else;
- the engine already reserves the per-title identification the wrapper needs
  (`MADEIRA_STEAM_APPID` / `MADEIRA_STEAM_APPPATH`, see `docs/ENGINE.md`).

This layer **requires the session host** (the unported part of the engine that
renders a Wine window and routes input); until it lands, the launcher screens
say "needs the session host" instead of offering a button that cannot work.

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
| Steam provider (sign-in, library, depots) | `Sources/Stores/SteamStore.swift` + `Sources/Steam/` | real: sign-in, owned library, depot downloads (device verification pending) |
| Epic provider | `Sources/Stores/EpicStore.swift` + `Sources/Epic/` | real: device-code sign-in, owned library (device verification pending); downloads next |
| Store screens | `Sources/UI/` + Library → Stores | Steam and Epic open real library sheets; the rest show the stub state |
| Launcher pipelines | — (needs the session host) | not implemented |
| Library, prefixes, paths | `Sources/Engine/`, `AppContainer.swift` | working |

## Roadmap for Doz Dock

Tracked in `docs/ROADMAP.md` (Phase 5 in `README.md`'s phase list); in order:

1. **Steam sign-in** — done: password + Steam Guard (code or approval) and
   QR; tokens in the Keychain. *(First device run pending.)*
2. **Owned library** — done: names, App IDs, art, in the Steam library sheet.
   *(First device run pending.)*
3. **Depots** — done: manifests, parallel chunked download, journaled
   resume, per-chunk SHA-1 verify, appmanifest record. Live Activity /
   background continuation still open.
4. **Launch hook** — hand the installed title to `WindozEngine.launch`, with
   `MADEIRA_STEAM_APPID` set for the titles that need it. Needs the session
   host.
5. **Epic** — sign-in and the owned library are done (device-code approval on
   Epic's own site; tokens in the Keychain; titles and art from the catalog).
   *(First device run pending.)* Depot downloads are next; the launcher/CDN
   endpoints are scoped to the launcher client and refused the device-flow
   session in development, so the downloads round starts by settling that
   authorization.
6. **Launcher pipelines** — EA and Rockstar wrappers once the session host can
   run them.
