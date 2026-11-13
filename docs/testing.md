# Testing & Fast Verification Loops

Pick the narrowest loop that exercises what you changed. Never kill or hijack a user's running `Pulse.app`, never flip their live settings manually to test UI, and never wait 30–40s for Apple notarization on every edit.

## 1. Choose the right test loop

| What you changed | Command | Typical time | Notes |
|---|---|---|---|
| `server.js` parsers / helpers | `node server.test.js` | `< 1s` | Runs 250 offline unit tests; no GUI or macOS tools needed |
| `public/index.html` UI / CSS / JS | `PORT=8797 node server.js` (or `Cmd-R` in dev `dist/Pulse.app`) | `~1s` | Isolated port alongside any live Pulse on `8787`; dev builds in `dist/` also read `public/` directly from the repo via `devCheckoutDir()` |
| AppKit layout / constraints (`UpdateStripView`, etc.) | `swift -e '...'` | `~1–2s` | Instantiate the view + `NSWindow` inline and print `.frame` / constraint results without building `.app` |
| Native macOS shell (`app/Pulse.swift`) — lightning dev loop | `./app/build.sh --fast && PULSE_SELFTEST=fast PULSE_AUTOCONFIRM=1 dist/Pulse.app/Contents/MacOS/Pulse` | `~7s total` | `--fast` uses `swiftc -Onone` + cached Sparkle/thermal/icon (`~3.6s`); `PULSE_SELFTEST=fast` skips Sparkle network + LaunchAgent cycles (`~3.4s`) while running all UI, layout, modal, and reopen checks |
| Native macOS shell — full offline build | `./app/build.sh --no-notarize` | `~6s` | Full `-O` build without notarization |
| Final verification / Touch ID (`Purge disk cache`) | `./app/build.sh --notarize && PULSE_SELFTEST=1 PULSE_AUTOCONFIRM=1 dist/Pulse.app/Contents/MacOS/Pulse` | `~45–55s` | Re-notarizes and staples `dist/Pulse.app` and runs full Sparkle + LaunchAgent checks |

> **Important `--fast` / `--no-notarize` caveat:** plain `./app/build.sh` auto-detects whether the existing `dist/Pulse.app` is notarized. If you ran `--fast` or `--no-notarize`, a plain `./app/build.sh` afterward stays unnotarized until you explicitly pass `--notarize`.

---

## 2. Testing safely alongside a live `Pulse.app`

Normal launches (`open dist/Pulse.app` or `dist/Pulse.app/Contents/MacOS/Pulse`) enforce a **single-instance check** on bundle ID `local.pulse.monitor`: a second launch activates the already-running instance and exits immediately without running your new binary.

**Do not** keep running `open dist/Pulse.app` while a previous instance is open — you will stare at the old in-memory binary.

### How to check whether a running instance is stale
```bash
pgrep -fl "Pulse\.app/Contents/MacOS/Pulse"
ps -p <pid> -o pid,lstart,command
stat -f "%Sm" dist/Pulse.app/Contents/Info.plist
```
If the process started **before** `dist/Pulse.app` was built, macOS is still running the old Mach-O binary in memory until the user quits and relaunches.

### How `PULSE_SELFTEST=1` stays isolated
`PULSE_SELFTEST=1 PULSE_AUTOCONFIRM=1 dist/Pulse.app/Contents/MacOS/Pulse` is built specifically to run cleanly next to a live user `Pulse.app`:
- **Bypasses single-instance exit** (`!isSelfTest` guard in `app/Pulse.swift`), so your test binary launches and tests itself directly.
- **Isolated port file:** `~/.pulse/port-selftest` (never touches `~/.pulse/port`).
- **Isolated LaunchAgent & logs:** `local.pulse.monitor.selftest`, `~/.pulse/boot-trace-selftest.log`, and `~/.pulse/daemon-selftest.log` (all cleaned up before exit).
- **Settings backup:** temporarily exercises `~/.pulse/settings.json` migration/round-trip and restores the original file on exit.

### How to test `public/index.html` without colliding
Always pass an alternate port when starting `server.js` for UI/browser testing:
```bash
PORT=8797 node server.js
```
Open `http://127.0.0.1:8797` in a browser or Playwright subagent and stop the server when done. This leaves `~/.pulse/port` and any running `Pulse.app` untouched.

---

## 3. Verifying native AppKit & WebKit fixes accurately

When changing native AppKit views (`app/Pulse.swift`), **measure** the layout rather than inferring from code:

1. **Quick AppKit repro (`swift -e`):** for constraint, sizing, or subview-positioning bugs (like `UpdateStripView` + `labelField` centering), paste the minimal class + `NSWindow` into `swift -e`, call `cv.layoutSubtreeIfNeeded()`, and print `view.frame` and `subview.frame`. Takes ~1–2 seconds.
2. **Permanent assertion in `runSelfTest()`:** add a programmatic check inside `runSelfTestLifecycleChecks()` (or the `evaluateJavaScript` probe in `runSelfTest()`) that temporarily enters the state under test, calls `layoutSubtreeIfNeeded()`, asserts exact frame/visibility invariants (for example `updateStripOk` verifying `stripH == 24`, `labelMidX == stripMidX`, and `web.frame.maxY <= updateStrip.frame.minY`), restores the prior state, and emits structured fields in `SELFTEST: {...}`.

That turns a one-off manual check into a permanent ~10s regression guard.
