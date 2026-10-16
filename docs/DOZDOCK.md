# Doz Dock

Doz Dock is windoz's **background download and sync engine for game stores** —
the part of the app that owns getting a game from a store to the device without
a desktop machine in the middle. This document says exactly what exists today,
what the pieces are, and the rules the implementation must keep.

> **State, plainly:** the stores are **not implemented yet**. The Steam and
> Epic screens in the app say so themselves (`StoreProviders.swift` throws
> `StoreError.notImplemented` with that sentence), and nothing in the UI
> pretends otherwise. What already works is the download engine the stores
> will be built on: queue, pause/resume, SHA-256 verification, free-space
> checks, Wi-Fi-only rules, and persistence across relaunch
> (`Sources/Downloads/`). It is in daily use for the Windows runtime files.

## The two layers

Doz Dock has two layers, and they are deliberately separate:

### 1. Native store clients (headless, in Swift)

The goal: sign in once, see the owned library with real art, and download the
game's own files with no store client running. The approach is the proven one
from SteamKit2 / DepotDownloader (and Legendary for Epic) reimplemented in
Swift inside the app:

- **Steam:** password + Steam Guard sign-in (QR later), owned-library fetch,
  then depot manifests and chunked downloads.
- **Epic:** OAuth sign-in, then manifests and chunked downloads.

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
| Steam provider (sign-in, library, depots) | `Sources/Stores/StoreProviders.swift` | honest stub |
| Epic provider | `Sources/Stores/StoreProviders.swift` | honest stub |
| Store screens | `Sources/UI/` + Library → Stores | show the stub state |
| Launcher pipelines | — (needs the session host) | not implemented |
| Library, prefixes, paths | `Sources/Engine/`, `AppContainer.swift` | working |

## Roadmap for Doz Dock

Tracked in `docs/ROADMAP.md` (Phase 5 in `README.md`'s phase list); in order:

1. **Steam sign-in** — password + Steam Guard, QR; tokens in the Keychain.
2. **Owned library** — names, App IDs, header art, in the console UI.
3. **Depots** — manifests, chunked parallel download, verify, resume, and the
   Live Activity / background continuation (where the host allows it).
4. **Launch hook** — hand the installed title to `WindozEngine.launch`, with
   `MADEIRA_STEAM_APPID` set for the titles that need it.
5. **Epic** — the same ladder against Epic's API.
6. **Launcher pipelines** — EA and Rockstar wrappers once the session host can
   run them.
