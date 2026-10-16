# Sideloading windoz

Everything in this document is about Apple's **free Apple ID** route: no paid
developer account and no jailbreak. The build comes from this repository's own
CI (`.github/workflows/build-ipa.yml`), which runs on GitHub's cloud macOS
runners — the developer's machine never needs to be a Mac.

> **Honesty note.** The IPA CI produces is *unsigned*. The sideloading tool you
> choose signs it with your own certificate. Everything below describes what
> that means on a current iPhone; where something does not work yet, it says so.

## 1. Get the IPA

1. Open the repository's **Actions** tab and pick the newest green
   **Build windoz IPA** run (a green run shows a ✅).
2. Download the artifact **`windoz-unsigned-ipa`** (bottom of the run page).
3. Unzip it. You get `windoz.ipa` (inside `windoz-ipa/` when you use the
   repository's helper scripts).

With the GitHub CLI installed you can do the same from the command line:

```sh
gh run list --workflow build-ipa.yml --limit 1
gh run download <run-id> -n windoz-unsigned-ipa
```

If the newest run is red, there is an **Autofix (issue watcher)** run linked
below it — see the README's *Automation* section. Do not sideload a red run's
artifact; the artifact only exists on green runs anyway.

## 2. Install it on the iPhone

### Option A — Sideloadly (Windows, USB cable)

1. Install [Sideloadly](https://sideloadly.io) and iTunes (or the Apple Devices
   app) on Windows.
2. Connect the iPhone, drag `windoz.ipa` into Sideloadly, enter your Apple ID.
3. Start. Sideloadly signs and installs the app.
4. On the iPhone: **Settings → General → VPN & Device Management → Developer
   App → Trust**, then launch Windoz.

### Option B — SideStore / AltStore (re-signs on a schedule)

These keep the app alive past the 7-day free-account window by re-signing on
the device. Install SideStore or AltStore first, then use its "+" button and
pick `windoz.ipa`. The same 7-day cycle applies, but the tool refreshes it —
as long as the phone and the helper can see each other every few days.

### Option C — LiveContainer (no re-signing of windoz itself)

[LiveContainer](https://github.com/LiveContainer/LiveContainer) runs the app
inside its own container. Windoz detects this itself and tells you what that
costs (Settings → **LiveContainer**, and the section on the setup wizard):

- JIT goes through LiveContainer's own **Launch with JIT** flow, using the
  script Windoz stages at `Documents/LiveContainer/windoz-jit.js`.
- App extensions never start, so the bundled JIT helper and widget extensions
  are unavailable on purpose.
- `BGTaskScheduler` does not continue downloads for guest apps — keep Windoz
  open (or in a LiveContainer window) while a download runs.
- The increased-memory entitlement is not on the host; big games are more
  likely to be jetsam-killed.

## 3. First run

The setup wizard checks the things that actually matter, in order: **JIT**,
**memory entitlement**, **storage**, and the **Windows runtime files**. It
never claims one of them is ready unless it probed it.

- **JIT (required to play).** Games cannot run until JIT is active. Windoz
  enables JIT through [StikDebug](https://github.com/StephenDev0/StikDebug):
  press **Open StikDebug**, let it attach, come back. The badge in Setup /
  Settings turns green, and Play re-checks it on every launch. Inside
  LiveContainer, use its "Launch with JIT" (see above) instead.
- **Memory.** The increased-memory entitlement is granted by the signing
  profile. A free Apple ID cannot grant it, and Windoz reports it as
  unavailable instead of pretending.
- **Runtime files.** Settings → Runtime installs the Windows runtime pieces.
  Microsoft's DLLs are fetched from Microsoft's own servers at install time;
  they are never bundled.

## 4. Add a game and play

1. **Library → Add local game** and pick an installed 64-bit game folder
   (from Files, iCloud Drive, or a zip you extracted). Windoz copies it into
   the app so it does not depend on the Files provider.
2. Open the game, set per-game options if you want, press **Play**.
3. What Play really does today is described in `docs/ROADMAP.md` and
   `docs/ENGINE.md` — the launch preflight (JIT, prefix, executable) is real;
   hosting the rendered session is the remaining engine port and the app says
   so on the game page rather than pretending.

## 5. The 7-day reality (free Apple ID)

Free-account signatures expire after **7 days**. The app stops launching until
it is re-signed. SideStore/AltStore automate this; Sideloadly means dragging
the same IPA in again. Nothing in the app loses data when this happens —
prefix, games, saves and downloads live in the app container.

## 6. Troubleshooting

| Symptom | Likely cause |
|---|---|
| "Unable to install" in Sideloadly/SideStore | Apple ID needs 2FA app password, or the free-account limit (3 apps) is full |
| App launches, badge stays red | StikDebug did not attach — open it again; inside LiveContainer, enable "Launch with JIT" for Windoz first |
| Build artifact missing | The newest run is red; check the watcher run linked in its summary |
| Run cancelled with "not acquired by Runner" | GitHub capacity; re-run the workflow — nothing is wrong with the build |
| Downloads stop in the background | Free-account/no-extension reality; see the LiveContainer notes above |
