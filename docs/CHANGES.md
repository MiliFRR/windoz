# windoz — changes

## 0.5.0 (2026-10-18) — the six-phase owner round

Built on 0.4.0. Six commits, one per phase, on `ci-050` (1/6 … 6/6); each
phase's `swiftc -typecheck` gate in CI is green, and 6/6 adds an off-device
test suite that CI now builds and runs on every push. The full
`build-ipa.yml` run and the keeper IPA (`windoz-ipa-keep/windoz-16.ipa`) are
recorded in the README's Known-issues ledger. Everything below that touches
the device says plainly what is compiled-and-tested and what still needs the
owner's iPhone.

### 1/6 — Idle heat: nothing runs that nothing needs

Observed: the phone warmed up just having Windoz open. Root causes were
several small always-running things; each is now bounded:

- Cover art decoded synchronously per frame — now decoded off the main
  thread behind a cache (`CoverArtCache`).
- The engine log published every appended line — now coalesced at ≤10 Hz.
- Home re-computed formatted dates constantly — now static text.
- The Steam CM socket stayed open after a refresh — it now closes the moment
  a refresh finishes with no download waiting on it.
- The launch watchdog kept ticking after reporting — it stops after its one
  warning.
- Added (DEBUG only): an idle monitor that logs CPU, thread count and
  thermal state every 30 s, so "it's warm" has numbers behind it.

**On iPhone:** leave Windoz on Home for 10 minutes and watch `windoz-logs` /
Xcode's console for the idle-monitor lines; the phone should stay
hand-temperature. Unverified on device as of this build.

### 2/6 — Tapping a game: one push per tap

Observed: a second tap during the game page's push animation stacked a second
game page; a controller Select while a page was up could re-point navigation
at a different game. Fix: the shelf ignores input while a game page is up and
the push is in flight; Back leaves the page. **On iPhone:** tap a game twice
fast, then mash Select on a controller — exactly one page, Back returns to
the same shelf position.

### 3/6 — A launch is a visible pipeline

A launch was previously a spinner with no story. Now `LaunchStatus.swift`
defines nine named steps — JIT, prefix, program, storage, launch mode,
screen, service + translator, process, first frame — and the start screen
renders them live with detail per step, elapsed time and Cancel from the
start screen. A failure keeps its steps, shows the real error, a suggested
fix, the engine log tail and Retry on the game page. One on-disk log
(`<storage root>/windoz-logs/windoz.log`) gains the engine's
`madeira-log.txt` tail at session end; UI updates stay coalesced at 10 Hz.
**On iPhone:** start the test game and watch the step list advance; pull the
log from Files if anything stalls.

### 4/6 — Built-in JIT: a helper extension, pairing, and honest fallbacks

Windoz now ships `WindozJITHelper.appex` (bundle id
`$(WINDOZ_BUNDLE_IDENTIFIER).jit-helper`), built on the vendored
`StikJIT.xcframework` (MPL-2.0; notices added) and a renamed `idevice`
Rust crate (`windoz_rppairing`; MIT; notices added). It attaches to the
engine by PID after launch. The app detects what's missing and says exactly
what to do: pairing file, LocalDevVPN, DeveloperDiskImage. StikDebug stays as
a fallback; the chosen method persists (`windozJITMethod`); pairing data
lives in the Keychain (`WindozJITPairing`). Settings > JIT and a guided
first-run screen expose it, and a launch attempts to enable JIT
automatically first. IDs derive from `WINDOZ_BUNDLE_IDENTIFIER`
(`com.milifrr.windoz`); Windoz adds its own `windoz://` URL scheme and uses
`localdevvpn://enable?scheme=windoz`.

Honest notes: Madeira's JIT shortcut over the network was **not** ported.
Built-in JIT cannot work inside LiveContainer — the app detects that, says
so, and falls back instead of pretending. **On iPhone:** run standalone
(sideload), open Settings > JIT, follow the pairing steps, then launch a game
and read the JIT step in the pipeline.

### 5/6 — Runtimes install themselves, from the vendors, hash-checked

First launch of a game now checks Wine Mono, Visual C++ 2005–2022 (x86 and
x64), .NET Desktop, DirectX June 2010 and its own `_CommonRedist` folder, and
offers to install what's missing — never at idle app start, only when a
session needs them. Ground rules kept:

- Downloads come **only** from the vendor's own URLs (WineHQ for Wine Mono —
  the pinned 11.0.0 tarball with its SHA-256 in the catalog; Microsoft and
  Epic/Steam for the rest). No Microsoft binary is bundled in this repo.
- The catalog is a bundled JSON manifest (`Resources/runtime-manifest.json`).
  Components with a pinned `sha256` are verified strictly. Unpinned
  vendor-servicing links (e.g. `aka.ms`) have their first download's SHA-256
  and final URL frozen into the prefix's ledger
  (`<prefix>/windoz-runtimes.json`); if the vendor later serves different
  bytes, Windoz **refuses** and offers an explicit "Accept the vendor's new
  file" in Settings. Never silent.
- Installers run as a real Windows session through the normal launch
  pipeline (staged to `drive_c/windoz-runtimes/`), one installer session per
  app run — the UI says to quit and reopen for the next one.
- State is per prefix and honest: downloaded Pending → `.sessionRan(date)`
  (the installer ran; whether it stuck is checked by probe files next open)
  → `.installed` only when the probe files exist. Failed downloads retry
  with 2 s / 8 s backoff, then cool off for 5 minutes; cancel and retry are
  buttons, cached downloads are reused.
- Refusals are named: 32-bit installers cannot run in this engine (no i386
  support) and say so; .NET Desktop 4.8 and DirectX June 2010 are listed as
  unavailable in this build with the reason; Steam client components stay
  with the existing Doz Dock flow.

**On iPhone:** open a game's page → redist card lists what's missing; install
Wine Mono first (small), then a VC++ package; the pipeline's Runtimes step
shows the session. Unverified on device as of this build.

### 6/6 — Epic downloads: root-caused, fixed, tested off-device

Observed: Epic sign-in worked, downloads failed instantly. Root causes were
found by auditing Windoz's port against **Legendary's** own source, and both
are fixed:

1. **Chunk URLs carried the manifest's signed query string.** The chunk base
   URL was derived with `URL.deletingLastPathComponent()`, which keeps the
   query — every chunk address became a request for the CDN *directory*
   (`…/guid/?token=…/ChunksV4/…`), answered 404 within a second. Legendary
   derives the base from the manifest URI without its last path part and with
   no query (`core.py get_cdn_urls`).
2. **The manifest and chunk fetches sent an `Authorization: bearer` header.**
   Legendary fetches both unauthenticated — the signed query string is the
   authorization. The header is gone from CDN fetches (the launcher API call
   keeps its bearer).

Also fixed and added in this phase:

- The assets response now parses **leniently** (`EpicProtocol.parseAssetElements`):
  a strict Codable decode could drop the whole list on any unexpected field,
  and the UI then said "Epic has no live Windows build", which was not true.
- The manifest is verified twice: the launcher service's SHA-1 over the raw
  bytes, and the binary header's own hash over the decompressed body.
- The download protocol moved to `EpicProtocol.swift` — Foundation + CryptoKit
  + zlib only, HTTP behind an injected transport — so CI compiles it on the
  host and runs `tests/host/epic-protocol-tests.swift` (mocked HTTP): the
  query-string and lenient-parse bugs are locked in as regressions, along
  with the launcher-hash check, encrypted manifest/chunk refusals, traversal
  refusal, pause/resume, retry with backoff, retry exhaustion, and a failed
  file being removed rather than half-written.
- The loop now pauses between chunks, resumes where it stopped, cancels on
  request, removes the in-progress file on any failure, and **skips files
  already on disk whose manifest hash matches** — cancel and restart does not
  re-download finished files.
- Every stage logs through `[epic-dl]` with query values redacted and no
  tokens anywhere; the UI shows the real sentence on failure, plus speed,
  ETA, Pause/Resume and Cancel.

Encrypted manifests and chunks are still refused by design, with the reason
named. **On iPhone:** open Epic, press Download on a title, and watch the
`[epic-dl]` lines (Settings > Logs). Success or failure, the log now says
which stage and why.

### Verification in this round

- Every phase's `swiftc -typecheck` gate in CI ended green: #22 (1/6), #23
  (2/6), #24 (3/6), #26 (4/6 — #25 caught a real mistake first), #29 (5/6 —
  #27 and #28 caught two more), and 6/6's gate, the first that also builds
  and executes the host tests: #30 caught one faulty test expectation (the
  all-zero file hash is the format's "no hash recorded" sentinel, which the
  test had mistaken for a bad hash) and #31 is green.
- `tests/host/epic-protocol-tests.swift` runs on every `ci-*` push from now
  on (the typecheck workflow gained the `tests/host/**` path trigger).
- The full unsigned-IPA pipeline ran on `main` after the merge: run #17
  (`7894113`) built every stage green; the artifact, the keeper
  (`windoz-ipa-keep/windoz-16.ipa`, SHA-256 in the README ledger) and the
  markers verified inside it are recorded there. The first attempt (#16 on
  `62339df`) caught a real release bug the typecheck gate cannot see — the
  ported `build/rppairing-ios/build.sh` had been committed without its
  executable bit and the step died at "Permission denied" before it ran;
  fixed in `7894113` (mode 100755).
- **No device claims.** Every phase above says "compiled and tested
  off-device" where that is all 0.5.0 can prove; the owner's iPhone is the
  judge. The on-device test checklist is in the README's ledger entry for
  0.5.0.
