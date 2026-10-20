# windoz — changes

## 0.9.0 (2026-10-20) — the owner round: picture, both Steam paths, pointer, power, display and input

Built on 0.8.0 (`main` = `2a63552`). Everything below is compiled and
typechecked; the IPA gate checks the version and the binary's feature strings.
**No device behaviour is claimed here.** The owner's iPhone run is the proof,
and the checklist at the end says exactly what to try.

### The session picture: rotation, its bar, and the post-boot freeze

Three separate causes were in the tree at once:

1. Windoz never called the engine's display-geometry contract. Madeira calls
   `winios_set_compositor_frame` (window points) and `winios_set_desktop_rect`
   (the compositor's own points) whenever the session's aspect rect changes.
   Without them the guest's desktop and its launcher/dialog windows kept the
   geometry they were given at attach, which is the small top-left picture and
   the cropped "frozen" window after a rotation.
2. The app wrote `CAMetalLayer.drawableSize` on the main thread during every
   layout. DXMT sizes that layer from the guest's swapchain off the main
   thread. The two writers raced, and a stale surface could keep presenting
   after the game had booted. The app no longer writes the drawable size; it
   seeds it once before registration and watches it thereafter.
3. The in-session HUD was pinned only when it was attached. After a rotation
   its old frame could leave the gear and Menu buttons outside the window.

The session host now:

- computes the aspect-fit guest rectangle from the **window**, not from
  SwiftUI's possibly stale surface bounds, and publishes both geometry calls;
- re-applies the layout after a 0.3 s settle on rotation, a guest display-mode
  change, a safe-area change, returning to the foreground, and a DXMT drawable
  size change;
- keeps the Metal host in the window and lets DXMT own the drawable;
- resets the HUD, pad, keyboard-and-mouse overlay and performance panel to the
  window's bounds on every layout pass;
- hides the engine's desktop compositor on teardown and shows it again on
  attach;
- logs a frame stall after 12 s with no new presented frame and re-publishes
  the display geometry once. It never kills the game; the log says when frames
  stopped and the process is still running.

The HUD keeps its compact status line and now uses two fixed 38-point icon
buttons (gear and Menu) with explicit width/height constraints, so their
hit targets do not depend on a title's intrinsic size after rotation. The
performance panel moved to the top right, below them.

### Doz Dock: the sign-in handoff was being cleared

`prepareLaunchMode` wrote the one-use sign-in transfer and set
`MADEIRA_DOCK_AUTH_FILE`, then `applyLaunchEnvironment` called
`DozDock.clearEnvironment()` and never put the path back. The dock host
therefore started without a sign-in and failed inside the session. The
validated game and handoff path are now kept for the launch, the environment
is restored after the deliberate clear, and the token is removed on every
successful or abandoned launch path. The preflight log no longer prints the
transfer path.

Doz Dock still refuses before the session opens when the Steam install record,
the verified client, or the saved Steam sign-in is missing; each refusal says
which one.

### The full Steam client: the launch Madeira proved, not only `MADEIRA_DESKTOP=1`

The 0.8 path ran `steam.exe` directly with no arguments. Valve's client is a
Chromium UI plus a Windows service client, so under Wine that path can start
without its SCM/rpcss chain and without the CEF flags that make its sign-in
window paint. The Steam desktop mode now mirrors Madeira's working launch:

- Windoz writes `C:\steam-launch.bat` into the prefix. The batch starts
  `services.exe` first, changes to Valve's folder, and runs `steam.exe` with
  `-no-cef-sandbox -cef-disable-gpu -console -nocrashmonitor
  -cef-disable-features=SegmentationPlatform,OptimizationTargetPrediction,OptimizationHints`.
- `MADEIRA_EXE=explorer.exe` and `MADEIRA_ARGS` tell Wine to run
  `/desktop=shell,<W>x<H> cmd /c C:\steam-launch.bat`, so the client's windows
  live on the session's shell desktop; `cmd` stays alive with the client.
- The path also arms the same virtual-desktop switches the validated Dock path
  uses: `MADEIRA_GDI_SHARED_SECTION`, `MADEIRA_JIT_IMAGE_RETIRE`,
  `MADEIRA_IMAGE_MAP_GUARD`, and `MADEIRA_DESKTOP_FIT`. It suppresses the fixed
  Steam identity (`MADEIRA_DOCK_SESSION=1`, `MADEIRA_STEAM_APPID`/`APPPATH`
  cleared) and forces `MADEIRA_WAIT_CHILDREN=1`, because Valve's client
  relaunches and forks helper modules.

Preflight and the Steam library sheet now require all three files the client
needs — `steam.exe`, `steamclient64.dll`, and `steamclient.dll` — instead of
only the 64-bit DLL. A partially unpacked client is reported with the missing
names, and the installer's "already prepared" fast path uses the same three
files so it can repair an old incomplete install.

The engine's desktop compositor is now revealed only for a desktop session.
A Direct launch after a dock or Steam-desktop session cannot inherit the
previous session's compositor view above the game.

### Pointer modes: direct touchscreen, or a real trackpad

`SessionPreferences` persists a session-wide choice; touchscreen remains the
default.

- **Touchscreen** is the original direct contract: the finger is the pointer,
  and the guest receives touch/mouse events at the aspect-fit or compositor
  mapped position.
- **Trackpad** is relative, not a touch mouse: one finger moves an owned
  desktop-pixel cursor, a tap posts left-click at that cursor, a still
  long-press arms a left-button drag, two fingers scroll (14 pt per wheel
  notch), and a two-finger tap posts right-click. Touch-down never teleports
  the cursor. The cursor is clamped to the guest monitor and clamped again
  after a mode change, backgrounding, or teardown, so no button is left down.
  Only touches that begin on the game surface count as a trackpad gesture: a
  finger held on the on-screen joystick or Space no longer turns the next
  finger into a two-finger scroll. Entering the mode posts one absolute move
  at the centre, so the first click cannot land on a stale cursor.

The mode is available live in the session's gear menu and as a default in
Settings → Session.

### Eco mode

Eco is the engine's own low-QoS guest-thread mode (`madeira_set_eco`), resolved
with `dlsym` so the app still launches if the pinned engine lacks it. The
session menu toggles it live, Settings → Session stores the default, and every
successful or abandoned session turns it off again while keeping the saved
choice. If the symbol is absent, the menu item is disabled and the log says
so instead of pretending.

### Resolution before launch, and DirectInput

- `GameResolution` adds exact presets — 1280 × 720, 1600 × 900, 1920 × 1080,
  2560 × 1440 — backed by `MADEIRA_SCREEN_W/H`. The old `resolutionScale`
  remains the `.scaled` fallback, so existing settings decode unchanged. The
  game page and the settings sheet show the preset and the text says it
  applies at the next launch; the session menu also exposes it.
- XInput remains always available to controller layouts. The per-game
  "Also expose a DirectInput joystick" setting sets `MADEIRA_DINPUT_PAD=1` for
  the next launch and is called out as launch-time only; the session menu
  toggles the same stored choice.

### The default keyboard-and-mouse controls

The old arrow/ESC-TAB-ENTER-SPACE row is replaced by the Madeira-style layout
the owner asked for:

- an on-screen thumb stick on the left that emits **real W/A/S/D key events**
  (not a virtual gamepad), with per-45°-sector press/release;
- a wide **Space** bar along the bottom centre;
- **Esc** at the top left with **Tab** directly beneath it.

Empty areas still pass touches to the game. The Xbox and PlayStation layouts,
their on-screen pads, and the DualSense glyphs are unchanged; PS5 continues to
use the XInput pad.

### What still needs the owner's iPhone

This build cannot prove device behaviour from a Windows host. Please test, in
this order, and send `windoz-logs/windoz.log` (Settings → Log) after any
failure:

1. Rotate a running game to landscape and back; open the gear and Menu after
   each rotation. The controls should stay on-screen and the game should stay
   centred, not shrink into the top-left.
2. Boot a game that previously froze after its first frame. If it freezes,
   attach the log: the stall line names the presented-frame count and whether
   the display refresh was re-published.
3. Launch a Doz Dock game with a saved Steam sign-in. If it refuses, send the
   log; the dock report fields are in it.
4. Install the full Steam client from the library and open it. Sign in inside
   the session; confirm the client paints and stays running.
5. Try both pointer modes, including tap, hold-drag, two-finger scroll and
   two-finger right-click in trackpad mode.
6. Toggle eco in the session gear menu, and compare a launch with it on/off.
7. Try 1280 × 720 and 1920 × 1080 from the game page (next launch), and a
   DirectInput-only game with the DirectInput toggle on (next launch).
8. Play with the default keyboard-and-mouse layout: joystick → WASD, Space,
   Esc and Tab.

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

## 0.6.0 (2026-10-18) — the launch-freeze / heat / downloads / phone-UI round

Built on 0.5.0. The owner ran the 0.5.0 keeper and sent five findings; each
one is answered below with its root cause — and every freeze/heat fix was a
bug in the app's own bookkeeping, not in the engine. Everything here is
**device-verification pending**; nothing below claims a device result.

### The launch freeze, and why LiveContainer could not relaunch

Observed: "whenever i launch a game it freezes in the launch screen"; after a
frozen launch, Windoz could not be started again from LiveContainer "for a
little bit"; the phone heated up during the freeze.

Root causes in `WindozEngine`'s launch path — three faults compounding:

1. **The stall watchdog never fired.** `startLaunchWatchdog()` was called from
   the launch body, which runs off the main actor after its first `await`.
   `Timer.scheduledTimer` schedules on the *calling* thread's run loop; a
   dispatch-worker thread never runs one, so the 180-second budget that was
   supposed to turn a stall into an honest failure could not fire. A wedged
   launch stayed on screen forever, with the engine's service process left
   burning CPU — the heat.
2. **The guest-start step had no way out.** The known wedge is the CPU
   translator waiting on the debugger's JIT script with the engine's init lock
   held; nothing bounded it, the UI stayed "starting" forever, and Play never
   came back — and nothing released the engine or the process slot, which is
   why LiveContainer had to wait for the old process to be reaped before it
   would host Windoz again.
3. **Every UI state write in `launch` was off the main thread** (phase, the
   session game, the step list, the failure card), so SwiftUI's updates were a
   coin toss — another way the launch screen could sit still while the engine
   moved underneath.

Fixes:

- The watchdog now starts on the main thread. The guest-start stage gets its
  own **160-second budget** with an exactly-one-resume guard (the same pattern
  as the Steam logon guard): whichever of "stage finished / budget expired /
  Cancel" happens first wins and the rest become no-ops — the double-resume
  crash class is designed out.
- A stalled launch is **marked spent** (`engineWedged`): later Play presses get
  a named refusal that says why and how to recover, instead of wedging the
  same engine lock again. The Windows service process is stopped (the heat),
  and a translator that answers *late* cannot start a guest behind the app's
  back (`sessionAbandoned` checks at every blocking step).
- **Quit Windoz** — the honest repair for both Wine's one-session-per-run rule
  and a wedged engine: a button on the failed-launch card and the game page,
  an entry in the session menu, and a section at the top of Settings →
  Advanced. It flushes the log and exits, so LiveContainer gets its slot back
  immediately instead of after a system kill.

### The Downloads tab

Observed: "game download not showing up in the downloads tab". Root cause:
Steam installs (Windoz's own depot downloader) and Epic's chunked installer
keep their progress inside their own store objects; the tab only read
`DownloadManager`, which game installs never touch. The tab now shows one
section per live source — Steam rows (progress, exact bytes, Cancel,
Resume/Dismiss on failure), Epic rows (phase, speed, ETA, Pause/Resume/Cancel)
and the general Windoz queue — and the tab carries a live count badge.

### Heat

Beyond the wedged-launch teardown above, the audit of every repeating source
in the app (timers, monitors, loops) found no idle repeater — the remaining
per-event cost was the on-disk log sink: one dispatch and one write syscall
per log line, and a chatty Wine/FEX boot logs thousands per second. The sink
now batches (flush every 0.5 s or at 256 KB; session-end tails flush first),
keeping the disk and a core out of the loop during the one moment the phone is
already working hard.

### The UI — phone-first, not console-first

Observed: "stuff is too big looks like ipad os ui for iphone". Root cause: one
fixed "10-foot" scale (42 pt wordmark, 280×380 hero tiles in a 460 pt rail,
240 pt game banner, fixed 200 pt covers, 18-20 pt padding) with no adaptivity
at all. The redesign keeps Windoz's look (dark blue-black, cyan/violet
accents, glass cards) and rebuilds the scale for a phone: a single `Metrics`
system every screen lays out from, a 30 pt wordmark, 176×238 hero tiles in a
330 pt rail, 112×150 shelf tiles, true box-art proportions in an adaptive
library grid (3:4), a 200 pt game banner, a 16 pt page rhythm everywhere, and
real phone sheets (large detents, visible drag handles) for the store and
settings sheets.

### Automation — the keeper is a URL now

- `scripts/check-ipa.py` is a real CLI (it was an untracked local script with
  0.5.0-era markers): it reads version/build from the IPA itself, checks the
  bundle, the built-in JIT helper, every subsystem string, and that the app's
  claimed version is actually compiled into the executable. `build-ipa.yml`
  runs it right after assembling, so a build that is not worth keeping fails
  before anything is uploaded.
- `release-ipa.yml` (new): when a build of `main` succeeds, its IPA artifact is
  attached to the GitHub Release `v<version>` automatically — created on the
  first build of that version, refreshed with `--clobber` on rebuilds. No
  hand-run keeper downloads, no local keeper folder needed for the next
  round.

### Verification in this round

- One commit per area on `ci-060`; typecheck gates #33 (`f2535ee`, the launch
  fix), #36 (the full tree, including the UI redesign) and #37 (`158f669`,
  the 0.6.0 bump) are green; runs cancelled by a newer push are not counted.
- The new IPA gate (`scripts/check-ipa.py`) caught two real release bugs on
  its first live runs, before anything was published: **#18** — the app
  bundle still claimed 0.5.0 build 5 because its Info.plist values were
  hardcoded in `project.yml` (fixed in `963cb1a`; the helper target had
  always referenced the build settings) — and **#19** — the workflow's own
  unanchored version grep caught a comment that mentions MARKETING_VERSION
  and rejected an already-correct IPA (replaced by the tested
  `scripts/read-version.py` in `4f51018`).
- **Run #20 is green end to end** on `4f51018`: the IPA check passed inside
  the workflow, and `release-ipa.yml` published the artifact automatically
  as the GitHub Release `v0.6.0` — `windoz-0.6.0-build6.ipa`, 78,293,503
  bytes, SHA-256
  `4BB881B58149CA4C07306EA62A9D4BE1B499F584395D201482AC1DFB90653EA6`
  (the same file is kept locally as `windoz-ipa-keep/windoz-17.ipa` and
  re-checked with the same checker).
- **No device claims.** The freeze, heat, download-list and layout fixes are
  exactly what the owner's next run judges; the checklist is in the README.

## 0.7.0 (2026-10-19) — use Madeira's engine, and a real iPhone UI

Built on 0.6.0. The owner ran the 0.6.0 keeper and replied, verbatim:

> NOTHING IS FIXED WITH THE WITH THE NEW VERSION JUST USE MADEIRAS ENGINE AND
> EVERYTHING FOR PLAYING THE GAMES AND FIX THE UI YOU DIDNT DO SHIT ABOUT IT

That report is the specification. 0.6.0 had changed the **failure handling**
around the launch path; it had not changed the launch path itself. This round
does both required things and nothing else: the game launch is Madeira's
sequence, and the screens are rebuilt as a compact native iPhone app. Every
item below is **compiled and type-checked, not verified on a device**.

### The launch: stop driving the engine ourselves

Observed (owner, 0.6.0 on device): launching a game still freezes on the
launch screen.

Root cause: 0.6.0's `WindozEngine.startGuestProcess` still ran Windoz's own
pipeline, not Madeira's:

1. **Wine never received its JIT pool.** The pinned Wine fork's
   `build/ntdll-unix/virtual_ios.c` executes every PE code page from the pool
   named by `WINE_IOS_JIT_RX` / `WINE_IOS_JIT_RW` / `WINE_IOS_JIT_SIZE`. Windoz
   never allocated that pool and never set those variables. The guest's
   executable mappings therefore had nowhere to live — the launch screen stayed
   black and the app waited forever.
2. **Windoz ran a second, unused translator.** Our code called
   `fex_initialize()` from Swift before starting the guest. Madeira's whole
   app never calls it on a game launch (a repository-wide grep leaves only its
   self-test); initialization done inside the C bridge is not the launch path.
   That call built an in-process FEXCore context and another large JIT pool —
   memory and CPU spent for nothing while the phone heated up.
3. **Teardown did the same.** Our stop paths called `fex_shutdown()` and
   `wineserver_stop()`; upstream has no app-side FEX shutdown to pair with.

Fix — Madeira's exact order now lives in
`app-windoz/Sources/Engine/JITPool.swift` and `WindozEngine`:

- Ask the attached debugger for the RX pool with `jit26_prepare_region`
  (Madeira's BRK protocol), with the same placement rules: at or above
  `0x119000000`, never inside the guest 64 GB window, never covering the
  `0x140000000` executable window. The pool is sized to the largest hole that
  actually fits (shrink to at least 256 MB), lower holes are plugged during the
  request so first-fit lands above the window, and three attempts re-roll bad
  placements.
- Mirror the pool read/write with `vm_remap`, mark it jetsam-exempt with
  `jit_make_region_no_footprint`, and publish exactly the three variables the
  Wine fork reads.
- Detach the debugger **before** Wine starts, as Madeira does, so StikDebug's
  budget cannot stall the app mid-game (`MADEIRA_DETACHED=1`).
- Start `wineserver_start`, wait for `wineserver_is_ready`, then
  `wine_process_start` — and nothing else. No `fex_initialize`, no
  `fex_shutdown`, no app-side translator lock on the launch path.
- A pool that cannot be granted is a **named failure** ("JIT is switched on,
  but no debugger is attached…") with the Quit path, not a frozen screen. The
  launch checklist has a new "Executable memory is ready" step so the device
  log says which half of the handshake failed.
- JIT readiness after the early detach is decided by the live pool
  (`JITPool.isReady`), not by a debugger staying attached, so the app does not
  claim JIT is off once the pool is serving the run.

### The UI: a native iPhone app, not a television

Observed (owner, every round since 0.5.0): "stuff is too big looks like ipad
os ui for iphone"; 0.6.0's smaller console was still a console.

Root cause: the design language itself — gradient wallpaper, glowing wordmark,
330 pt hero carousel, 176×238 tiles, 200 pt game banner, glass cards, tracked
uppercase section labels, custom 22–30 pt rounded type. Rescaling those
elements for a phone kept them oversized and kept the "10-foot" feel.

Rebuilt:

- **System chrome.** Grouped system backgrounds, flat inset-grouped cards
  (12 pt radius, no glass, no stroke, no glow), standard iOS type, sentence-case
  section headings, one accent colour.
- **Home** no longer has a wordmark or hero carousel. It is a large-title
  screen with a compact "Continue playing" shelf (124×166 covers), a "Recently
  added" shelf (96×128), and a plain all-games list with 44×58 covers. Empty
  state is the system `ContentUnavailableView`.
- **Library** is a three-column grid (adaptive 100–140 pt, caption titles) and
  store rows are ordinary grouped cards with small bordered buttons.
- **Game page** lost its 200 pt hero banner. The header is an 82×110 cover plus
  executable name, compatibility, anti-cheat and playtime; the primary action
  is a standard full-width "Play" button. Everything else stays in compact
  grouped cards.
- **Settings and Setup** use the system grouped List and bordered/bordered-
  prominent buttons; the Downloads tab keeps its aggregated rows in compact
  cards. The in-session HUD was already 12–13 pt and is unchanged apart from
  the new pool step.
- The app still forces dark mode in 0.7.0 because the session and store
  surfaces contain many intentional white-on-black overlays; the backgrounds
  and cards are now system dark colours rather than hand-mixed gradients.

### Verification in this round

- One commit per area on `ci-070`: `abf1859` (engine), `7fa218f` (UI), then
  the pool-pinning, cover-size, step-order and step-marking follow-ups. The
  final tree (`b8b3fed`) is type-checked green by `typecheck.yml` run **#43**
  (2026-10-19); earlier gates #39 and #40 were green too, and were cancelled
  or superseded only by later pushes on the same branch.
- The 0.7.0 version bump is part of this tree. `build-ipa.yml` **run #21**
  (2026-10-19, `main` = `7f5cf67`) is green through every stage — including
  the IPA gate — and `release-ipa.yml` run #4 published the artifact as the
  GitHub Release
  [`v0.7.0`](https://github.com/MiliFRR/windoz/releases/tag/v0.7.0)
  (`windoz-0.7.0-build7.ipa`, 78,276,079 bytes, SHA-256
  `81ED949EFBCF016CD48B07E69E1F67C550F4004F9F8B026CFC14D6873621DF69`).
  The same file is kept locally as `windoz-ipa-keep/windoz-18.ipa` and
  re-checked with `scripts/check-ipa.py --require 0.7.0 --min-build 7`; the
  executable also carries the new launch-path strings (`[jit-pool]`,
  `WINE_IOS_JIT_RX`, `jit26_prepare_region`, `MADEIRA_DETACHED`).
- **No device claims.** The owner's next run is the judge: launch a game and
  watch the new "Executable memory is ready" step; the pool must appear in the
  log before Wine's service starts, and the game must reach its own window
  instead of the black launch screen. The UI checklist is in the README.

## 0.8.0 (2026-10-19) — swap memory, full Steam support, session settings, modern UI

Built on 0.7.0. The owner ran the 0.7.0 keeper, confirmed direct launches
work, and replied, verbatim:

> running the game without steam works now add swap memory support fix steam
> with doz dock and full steam support add a settings icon when luanching a
> game with controller support or keybaord controls changeing from that menu
> add a default layout for kbm and a xbox controller layour and a ps5
> controller layout add a toggle for perforamnce stats on screen in there make
> it have fps low 1% and low 0.1% ram usage and cpu usage battery usage remake
> the ui to look more modern last redesign you did what a step in the right
> place

This round delivers all of it. The 0.7.0 launch path is untouched: direct
launches keep the pinned engine's own sequence. Every item below is **compiled
and type-checked, not verified on a device**.

### Swap memory — the engine's own tier, switched on from Settings

Observed (owner): "add swap memory support".

Root cause of the missing feature: the pinned engine has a file-backed guest
memory tier, and the iOS bridge already arms it — `wine_process_start` in
`WineProcessBridge.m` reads `swap-mb` from `Documents/madeira.cfg`, and when
the value is at least 64 MB it recreates
`NSTemporaryDirectory()/madeira-swap.bin` with `NSFileProtectionNone` and
exports `MADEIRA_SWAP_FILE` / `MADEIRA_SWAP_MB` to the guest. Windoz never
wrote that file, so the tier was always off. No engine change was needed.

Fix (`Sources/Engine/MadeiraConfig.swift`, Settings → Memory):

- Off / 1 GB / 2 GB / 4 GB — the same choices, units and default (Off) as
  Madeira's own Memory page. A size the bridge would discard (under 64 MB) is
  stored and shown as off, never as a size that silently does nothing.
- Coverage picker for `env.MADEIRA_SWAP_COVERAGE` — Large allocations
  (default), 1 MB and larger, overflow allocations, whole reservations — with
  one honest sentence per mode; `classic` writes no env line because it is the
  engine's default.
- The writer merges rather than replaces: comments and every key Windoz does
  not own stay byte-for-byte in `Documents/madeira.cfg`, the write is atomic,
  the file is read back and verified against what the bridge will parse, and
  a failure is surfaced in Settings and the log with its reason. If removing
  the swap keys leaves no meaningful line, the file is deleted instead, so the
  engine is never handed an empty cfg.
- Takes effect on the **next launch** (the bridge reads the file when the
  session starts). The launch log states the tier it found: on (with size and
  coverage), or off.

### Doz Dock: every library the client knows, and progress while it works

Observed (owner): "fix steam with doz dock" — a Doz Dock launch that never
reached the game.

Root causes, from Windoz's side (no device log of the owner's run exists;
these fixes are code-level):

1. **Only Steam's canonical folder was searched.** Paths were joined onto the
   known Steam root by string concatenation, so a library on any other folder
   listed in `libraryfolders.vdf` was invisible: validate answered "install
   record not found" for a game Valve's client could plainly see, and the
   dock refused before starting. The dock now parses **every library** the
   client knows (`DozDock.libraries`: every `libraryfolders.vdf` on C:),
   resolves each manifest relative to its own library, lists games across the
   union with shared-only records filtered out, and unions the depots each
   library lent. The same caps and path-safety rules as Madeira's dock apply
   unchanged (16 libraries, 2000 manifests, `c:/` only, one safe folder name
   per record).
2. **A slow client start read as a stall.** The session HUD now watches
   `C:\madeira-dock.txt` while the dock runs (every 0.5 s,
   `DozDock.progressStage`) and shows the live stage — handoff accepted,
   connection, offline logon, updates, launch — as a chip; a refusal or
   failure reads in plain words (`humanFailure`) in the HUD instead of a
   silent black screen. Report files are still deleted after the session, and
   the chip clears with it.

### Full Steam support: the client as a session, and imports

The other half of "full steam support": Valve's client is now usable for what
Windoz's own downloader cannot do — buying, updating, and installing titles
whose manifests aren't reachable headlessly.

- **Open Steam** (Steam library sheet → Steam client card): starts
  `steam.exe` from the installed client components as an ordinary session
  through the engine (`.steamDesktop`), signed in with the stored token, so
  the full client opens for browsing, buying and installing.
- **Add installed games**: scans all Steam libraries inside the prefix (the
  new `Sources/Steam/Content/SteamClientLibrary.swift`) for titles Valve's
  client installed, adds or completes their library entries (new entries
  default to the Doz Dock mode so they launch through the client), and fetches
  missing artwork from Steam's CDN.
- The client card reports the prepared state (`steamclient64.dll` present),
  installs the pinned client components with live stage text, and then offers
  Open Steam and Add installed games. Nothing about the client path is
  simulated: it is Valve's own client, Valve's own components.

### The session: a settings menu, three control layouts, performance stats

Observed (owner): "add a settings icon when launching a game ... changeing
from that menu add a default layout for kbm and a xbox controller layour and
a ps5 controller layout add a toggle for perforamnce stats".

The session HUD has a gear button that opens the in-game menu
(`SessionControls.swift`, `SessionPerformance.swift`):

- **Controls** — Keyboard & mouse (default), Xbox, PlayStation 5. Per game,
  stored with the game's settings (Game page → Controls shows the same
  picker), changeable while the game runs:
  - *Keyboard & mouse*: the session keeps the key row, touch stays the game's
    own pointer, and a connected controller is translated to keyboard and
    mouse — WASD on the left stick (dead zone 0.35), the mouse on the right
    stick (1500 px/s, squared response), the template keys on the buttons —
    the game is never told a controller exists.
  - *Xbox / PlayStation 5*: a physical controller and the on-screen pad merge
    into one XInput snapshot (dead zone 7849, the engine's value) published
    to slot 0 via `winios_gamepad_set_state`; the on-screen pad is drawn with
    Xbox or DualSense glyphs and the key row hides. The PS5 layout is honest
    about what it is: the same Xbox-style pad with DualSense art — Windoz
    does not present a DualSense.
- **Performance stats** — one persisted toggle (all games). The overlay
  samples the engine's own presented-frame counter at 4 Hz and shows: FPS
  (smoothed), 1 % and 0.1 % lows (percentiles of the last minute of frame
  times), RAM (the app's own physical footprint), CPU (process thread times
  as a share of all cores, ported from Madeira's CPUMeter), and battery
  (level, plus the change since the session started). Every number is
  measured on the device; nothing is estimated.

### The UI: a modern pass, in the same direction

Observed (owner): "remake the ui to look more modern last redesign you did
what a step in the right place". 0.7.0's compact-native direction stays; this
round is a polish pass, not another rebuild:

- One gradient, used only for primary actions — Play buttons and the featured
  card's play control — the accent sweeping into indigo. Everything else
  stays flat system colour; no glow, no wallpaper.
- **Home** now opens with a full-width featured card: the most recently
  played game drawn with its hero art, title, last-played line and one play
  affordance; the rest of "Continue playing" follows as the compact shelf,
  renamed "Recently played".
- **Library** gained a system search field and a row of filter chips
  (All / Imported / Steam / Epic) that compose with search.
- The Game page's Controls section is the new layout picker (the old custom
  touch-overlay editor's layouts were never read by the session, and its
  stale note said so; the picker replaces it).

### Verification in this round

- The round was built on `ci-080` (feature commit `0360a14`; the docs and the
  compiler catches that followed ended at `891d549`). The four small helper
  scripts the round used (`check-build.*`, `watcher-*`) stay untracked.
- The typecheck gate ended green on `891d549` — `typecheck.yml` run **#50**
  (workflow 39302982508): the app's Swift, the Epic protocol host tests and the
  XcodeGen validation all passed. Run #49 had already been green on `6367d83`;
  the red runs in the round were the gate catching real compile errors, not
  flakes.
- `build-ipa.yml` **run #23** (workflow 39303590722, `main` = `891d549`,
  success, 2026-10-19) built every stage — LLVM, Wine/FEX/DXMT/D3D12, the app,
  the IPA — and the IPA gate passed. The round's first build, run **#22**
  (39298248062, `6367d83`), failed only at that gate:
  `AppContainer.displayVersion` still said `0.7.0` while `project.yml` said
  `0.8.0`; `891d549` fixed it.
- `release-ipa.yml` run #6 (39310254300) published **`v0.8.0` — "Windoz 0.8.0
  (build 8)"** with `windoz-0.8.0-build8.ipa`, 78,511,877 bytes, SHA-256
  `824070056B954F221444E4B4EC337BF55C4E7CEBDAD543E931C698BFC039FBBA`. The IPA
  is kept as `windoz-ipa-keep/windoz-19.ipa` and was re-checked with
  `check-ipa.py --require 0.8.0 --min-build 8`: app and helper both claim
  `0.8.0` build 8, `MinimumOSVersion` 26.0, every subsystem marker present.
- The shipped executable also carries the 0.8.0 feature strings:
  `env.MADEIRA_SWAP_COVERAGE`, `madeira.cfg`, `swap-mb`, `MADEIRA_SWAP_MB`,
  `libraryfolders.vdf`, `steamDesktop`, `winios_gamepad_set_state`,
  `session-handoff-stage`, `madeira-dock.txt`, `Steam client`,
  `Add installed games`, `Keyboard & mouse`, `PlayStation 5`.
- **No device claims.** The owner's next run is the judge: the Settings →
  Memory page must write `Documents/madeira.cfg` (the log says which tier the
  launch found), a Doz Dock launch must show the stage chip advancing, Open
  Steam must reach the client's own window, the ⚙ menu must switch layouts,
  and the stats overlay must show all six numbers. The checklist is in the
  README.
