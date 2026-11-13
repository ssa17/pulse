# Contracts — how the components talk to each other

The three components (`server.js`, `public/index.html`, `app/Pulse.swift`) are
coupled by a few **implicit** contracts. There is no shared type definition, so
**if you change one side, change the other** — a mismatch fails *silently* (the UI
shows "—", the menu-bar graph goes blank) rather than erroring.

## The snapshot (server.js ⇄ index.html)

`server.js` builds one snapshot per tick; `index.html` reads exactly these fields
(see `onTick`, `renderSys`, `renderPanel`, `renderDrawer`):

```js
{
  t: <ms epoch>,
  version: <string|null>,   // app version — source of truth is app/Info.plist
                            // (PULSE_VERSION env in app mode, plist read in web mode)
  serverMtime: <sec epoch>, // mtime of the running server.js at boot (used by Pulse.swift
                            // & index.html so UI and backend never go out of sync)
  uiMtime: <sec epoch>,     // mtime of index.html on disk (auto-reloads UI on edit/rebuild)
  sys: {
    model, chip, memLabel,      // from system_profiler; null until it finishes loading
    cores, memTotal,            // memTotal in bytes
    cpu:  { user, sys, idle, total, temp, eCores, pCores }, // percents (total = 100 - idle); temp in °C or null; eCores/pCores cluster load %
    loadAvg: [ 1m, 5m, 15m ],   // load averages from os.loadavg()
    mem:  { free, used, apps, wired, compressed, cache, inUse },  // bytes. Activity-Monitor-style:
                                                                 // wired/compressor are vm_stat measurements,
                                                                 // cache = vm_stat filebacked + purgeable (capped
                                                                 // to the non-wired pool), apps = the residual; the
                                                                 // four segments sum to `used`. `inUse` =
                                                                 // used − cache = the "Memory Used" figure AM
                                                                 // shows (App + Wired + Compressed).
    memDetail: {                                            // extra vm_stat counters (bytes), informational only —
      active, inactive, speculative,                        // NOT part of the normalized `mem` segments above;
      purgeable, filebacked, storedCompressed              // powers the memory info popover in index.html
    },
    memPressure: { level, state }, // kern.memorystatus_vm_pressure_level (1=normal, 2=warn, >=4=critical)
    swap: { used, total },         // bytes (total is auto-allocated by macOS; UI highlights `used`)
    uptime: <seconds>,
    net:  { down, up, ready },  // bytes/sec; ready=false until 2nd netstat delta lands (or stale >15s)
    disk: { mbps, ready },      // MB/s, read + write; ready=false until 1st iostat window completes (or stale >15s)
    batt: { pct, charging, external, powerW, batteryW, adapterW, minsRemaining }, // AppleSmartBattery + pmset
    sleepBlockers: { display, system, count }, // active Prevent*Sleep assertions from pmset -g assertions
    gpu:  { pct, mem, name, cores }, // Apple Silicon only (ioreg AGX/IOAccelerator); pct null elsewhere.
                                     // pct = delta of accumulatedGPUTime ÷ window ÷ MGPU units; mem = in use system memory (bytes);
                                     // name/cores from the GPU node
    thermal: { level, state, cpu, min, max }, // level 0..3 (pmset), state: nominal|slowed|throttled; cpu: temp in °C or null;
                                              // min/max: the machine's observed cold–hot range since the sampler
                                              // started (null until the first reading). UIs colour on absolute 40°C..90°C+ scale
    blacklist: { total, enabled, kills },     // persistent auto-kill rules count & kill total (~/.pulse/blacklist.json)
    procCount, appCount
  },
  apps: [{
    key, name, kind: 'app' | 'system' | 'other',
    bundle,                    // .app path or null
    icon,                      // /icons/<hash>.png or null
    cpu,                       // % of ALL cores (16 cores fully busy = 100)
    mem,                       // bytes — physical footprint per process (top's MEM,
                               // the number Activity Monitor shows; RSS fallback),
                               // summed over the app's processes
    power,                     // summed top POWER energy impact score, or null before top runs
    wakeups,                   // summed delta idle wakeups/s across processes
    assertions: [{ pid, type, name, dur, preventsSleep }], // active pmset assertions for this app
    procs, users: [..], mainPid,   // mainPid is always > 0 or null (PID 0 kernel_task is never killable)
    processes: [{ pid, ppid, user, name, exe, cpu, mem, power, wakeups, vsz, stat, etime, args, role, desc }]
  }]
}
```

## The /api/status shape (server.js ⇄ Pulse.swift)

```js
{ t: <ms epoch>,                     // sample completion timestamp
  serverMtime: <sec epoch>,          // mtime of server.js at boot (triggers live backend reload on rebuild)
  bootTrace: { start, listen, firstSnapshot }, // epoch ms timestamps for startup trace logging
  memDebug: { rss, heapTotal, heapUsed, external }, // Node V8 memory telemetry (bytes)
  cpu: { user, sys, idle, total, temp, eCores, pCores }, // SYSTEM cpu (from top) — NOT an app; temp in °C or null; eCores/pCores load %
  loadAvg: [ 1m, 5m, 15m ],          // load averages from os.loadavg()
  memPct, memUsed, memTotal,         // AM-style: memUsed = used − file cache
  memPools: { wired, active, compressed, free }, // bytes per memory pool for segmented bar & breakdown
  memPressure: 'normal' | 'warn' | 'critical' | null, // kern.memorystatus_vm_pressure_level
  swapUsed: <bytes>,                 // vm.swapusage used bytes
  batt: { pct, charging, powerW, minsRemaining }, // battery + system wattage
  sleepBlockers: <int>,              // active Prevent*Sleep assertions count
  gpuPct,                            // Apple Silicon GPU utilization %; null if unavailable
  gpuMem,                            // Apple Silicon in use GPU memory (bytes); null if unavailable
  thermal: { level, state, cpu, min, max }, // pmset level 0..3 + nominal|slowed|throttled; cpu temp in °C or null; min/max = observed range (colours use a 10°C-floored span of it)
  net: { down, up },                 // bytes/s summed across all interfaces — the SAME
                                     // scale as the snapshot's sys.net; each side formats
                                     // B/KB/MB/GB on its own (no in-band conversion)
  bootTime: <sec epoch>,             // menu computes uptime from it
  menuRows: [ <id>, ... ],           // ordered VISIBLE dropdown row ids
                                     // (cpu, gpu, memory, thermal, network,
                                     // uptime) —
                                     // absent id = hidden; the menu rebuilds
  barRows: [ <id>, ... ],            // VISIBLE status-bar capsules (cpu, gpu,
                                     // memory, network); capsules follow
                                     // menuRows order; empty = static “P” button
  layoutGen: <int>,                   // settings-file revision; the app skips
                                     // layouts older than its own last write
  purge: <id> }                      // OPTIONAL — only while a purge is queued;
                                     // the app shell runs the in-process prompt
                                     // and reports via /api/purge-result
```

`Pulse.swift` (`StatusController.poll`) reads: `cpu.total`, `cpu.user`,
`cpu.sys`, `memPct`, `memUsed`, `memTotal`, `gpuPct`, `thermal`, `bootTime`,
and `menuRows`/`barRows`, plus `bootTrace.firstSnapshot` for the startup trace.
The menu renders each stat row display-only (value at the row's end, proportional
bar below — the thermal row fills in thirds per pmset level); `menuRows` drives
dropdown row order/visibility and `barRows` the status-bar button, which shows one
capsule per stat visible in BOTH (in menu order — a static “P” if none; thermal
& uptime are menu-only); all rows stay enabled so AppKit doesn't dim them;
`Open Pulse` is the only opener. Note the naming: `cpu` is the system CPU object,
not an app.

## Cross-component protocols

- **UI delivery & `file://` backend injection**: in app mode, `Pulse.swift` loads
  `public/index.html` immediately at launch via `WKWebView.loadFileURL` with
  `?r=<ts>` (and `&backend=http://127.0.0.1:<port>` on warm reuse or reopen),
  resolving `public/` from a dev checkout if present or `Contents/Resources/public/`
  otherwise (`reload()` uses the same loader to bust WebKit cache cleanly). On
  cold launch before any backend answers, `index.html` (`!hasBackend()`) paints
  full chrome + shimmering skeletons in `starting…` state without polling `file://`.
  When a backend becomes ready, `Pulse.swift` invokes
  `window.__pulseSetBackend("http://127.0.0.1:<port>")` via `evaluateJavaScript`
  (kept non-`async` in JS because `WKWebView` rejects Promise returns) so
  SSE/fetch/icons connect in place with no reload; switching backends (e.g., race
  → LaunchAgent daemon) calls `__pulseSetBackend` again seamlessly. All UI network and icon requests go
  through `apiUrl()`, and `server.js` emits `Access-Control-Allow-Origin: *`
  (`GET`/`POST`/`OPTIONS` preflight `204`) — safe under invariant 1 because
  `server.js` binds exclusively to `127.0.0.1`. Web mode continues to serve
  `index.html` directly over HTTP from `GET /`.
- **Port discovery & spawn-race**: the backend writes `<port>\n<pid>\n` to
  `~/.pulse/port` (`PULSE_PORT_FILE` overrides in self-tests) when no different
  live owner holds it (`canWritePortFile()` / `isPidAlive()`), and removes it on
  exit only if the file still matches both its own port and pid. A new launch
  reuses a running backend when its pid (if present) is alive and that port
  answers `/api/snapshot` with a matching `serverMtime` (`checkServerAlive` in
  `Pulse.swift`, 1.0s async cap). If the LaunchAgent daemon is configured but
  cold/stale (causing `launchd` `ProcessType: Background` startup to take ~2.5s),
  `refreshDaemonOrSpawn()` launches a direct `node` racer (`PULSE_RACE=1`, which
  skips writing the port file) in parallel with `bootstrap`/`kickstart`: the
  racer feeds the UI in ~400ms, then when the LaunchAgent daemon is up and healthy
  (`pid != racer`), `Pulse.swift` swaps live via `__pulseSetBackend`, marks
  `daemon_migrated`, and terminates the racer (promoting the racer via
  `writePortFileIfUnowned` if the daemon fails or times out).
- **App-spawned vs LaunchAgent backend**:
  * **App-spawned**: when no daemon is running, `Pulse.swift` resolves `node`
    (`findNodeFast` → async login-shell fallback) and spawns `node server.js`
    with `PULSE=1 PORT=0` and `NODE_OPTIONS="--max-old-space-size=64 --max-semi-space-size=8"`,
    reading `PULSE_LISTENING=<port>` from stdout. The backend runs an orphan
    watchdog (exits if its parent dies) and the app terminates it on `Quit Pulse`.
  * **LaunchAgent daemon ("Start at login")**: toggling "Start at login" on
    writes `~/Library/LaunchAgents/local.pulse.monitor.plist` (`RunAtLoad` +
    `KeepAlive`, `PULSE=1 PULSE_DAEMON=1 PORT=0`) and runs
    `launchctl bootstrap gui/<uid>`. Because `ppid == 1` (and `PULSE_DAEMON=1`),
    the orphan watchdog is skipped and the sampler survives window closes, app
    quits, and reboots. On `Quit Pulse`, the app exits while the daemon keeps
    sampling; the menu bar also offers **"Quit Pulse & Stop Background"** (which
    runs `launchctl bootout` before exiting). On Sparkle auto-update
    (`SPUUpdaterDelegate.updaterWillRelaunchApplication`) or when `Pulse.swift`
    detects a stale plist/mtime at launch, the daemon is `bootout` +
    `bootstrap`ped with the new bundle so UI and backend never split-brain.
- **Window close ≠ quit & WebView memory lifecycle**:
  * By default (`closeBehavior == "background"`), closing the dashboard window
    hides it while the app, backend, and menu-bar status item stay alive.
  * When `keepDashboardInMemory == false` (default), `windowWillClose` tears down
    the `WKWebView` (keeping the `NSWindow` with `isReleasedWhenClosed = false`)
    so `com.apple.WebKit.WebContent`, `Networking`, and `GPU` XPC processes exit.
    Re-opening via the menu bar (`Open Pulse`), Dock icon
    (`applicationShouldHandleReopen`), or a second launch (`DistributedNotificationCenter`
    `local.pulse.monitor.reopen`) recreates the webview and loads against the
    live backend in <500ms.
- **Settings & `~/.pulse/settings.json` schema**:
  Accessible directly from the dashboard header (`#settings-btn` / `⌘,` opens the
  in-dashboard `#settings-modal`, bridged to `Pulse.swift` via the `pulseSettings`
  `WKScriptMessageHandler` and falling back to `GET`/`POST /api/settings` in web
  mode), from the app menu (`Settings…` / `⌘,`), or from the menu-bar status item
  (which opens the dark-themed native `SettingsWindowController` when the dashboard
  window is closed). The status menu itself offers the stat rows (order and
  visibility configurable in Settings via `menuRows`, below) plus Open Pulse,
  Settings, and Quit — every setting lives in the dashboard modal / native Settings window.
  All `launchctl` operations run asynchronously on `LaunchAgentManager.workQueue`
  and hand off the active port via `~/.pulse/preferred-port` so toggling "Start at
  login" never blocks the main thread or reloads the dashboard. Persisted at
  `~/.pulse/settings.json`:
  ```json
  {
    "version": 2,
    "startAtLogin": false,
    "closeBehavior": "background",
    "keepDashboardInMemory": false,
    "menuRows": ["cpu", "gpu", "memory", "network", "uptime"],
    "barRows": ["cpu", "gpu", "memory", "network"]
  }
  ```
  `menuRows` is the ordered list of VISIBLE dropdown row ids from
  `cpu, gpu, memory, thermal, network, uptime` — absent id = hidden row (default
  hides thermal). `barRows` is the set of VISIBLE status-bar capsules from
  `cpu, gpu, memory, network` (thermal/uptime have no capsule); an ABSENT key
  derives from `menuRows`, and an EMPTY array is a valid layout for either (menu:
  actions only; button: static “P”). A missing/non-array value falls back to
  the defaults. Hidden rows keep their slot in the settings list, so
  re-enabling restores their original position.
  Unversioned (or v1) files migrate to `version: 2` by dropping the legacy
  `statusBarGraphType` key while preserving any unknown keys. The "Start at
  login" toggle always reflects actual `launchctl` / plist state.
- **Startup & reopen trace (`~/.pulse/boot-trace.log`)**:
  `BootTracer` in `Pulse.swift` and the `pulseTrace` `WKScriptMessageHandler` in
  `index.html` log timestamped stages (`app_launch`, `webview_ready`,
  `port_probe_start` / `race_start`, `daemon_reused` / `backend_spawn`,
  `pulse_listening` / `race_backend_ready`, `bootstrap_call` / `bootstrap_done` /
  `kickstart_call` / `kickstart_done`, `port_file_seen`, `backend_alive`,
  `webview_load`, `dom_content_loaded`, `skeleton_paint`,
  `backend_first_snapshot`, `menubar_first_sample`, `first_sse_message`,
  `first_render`, `daemon_migrated`, plus `window_reopen` sessions), keeping
  the last 10 sessions (`boot-trace-selftest.log` when `PULSE_SELFTEST=1`).
  **Privacy invariant**: only stage names and numeric timestamps are ever
  written — never process names, arguments, or paths.
- **Self-test DOM & lifecycle contract**: with `PULSE_SELFTEST=1`, `Pulse.swift`
  captures the pre-injection `file://` skeleton (`startingSkeletonOk`: `starting…`,
  `.skel-row > 0`, `__pulseSetBackend` function, blank `#cpu-big`), then clicks
  `#rows-cpu .row`, counts `#dtable .prow`, reads `#machine`, `#cpu-big`,
  `#mem-big`, `#live-text`, `#ver` from `index.html`, exercises the LaunchAgent
  install/remove round-trip via isolated `port-selftest` (`daemonRoundTripOk` +
  `daemonPortOwnerOk`), verifies `skeleton_paint` in `bootTraceOk`, exercises the memory info
  popover (clicks `#mem-info` → reads `#mempop` open + `#pop-wired`, `#pop-comp`,
  `#pop-cache`, `#pop-webkit-note` → closes it), exercises the in-dashboard
  Settings modal (`#settings-btn` → `#settings-scrim.on` → `#settings-close`,
  reported as `dashboardSettingsOk`), exercises the Updates card (fake
  `window.__pulseUpdate` with an `available` version → `#st-update-card` shows
  with "Update to vX…" → restore → `#st-check-card` shows, reported as
  `updatesCardOk`), then runs a **real** update check through the card button —
  reported as `checkFlowSample`/`checkFlow`/`checkFlowOk`: all timing lives
  *app-side* (this WebKit's `evaluateJavaScript` doesn't flatten promises), so
  the app samples the card 200ms in (the ramp is 1.1s: the desc must still say
  "Checking…", the button greyed, the bar not at 100% — even if the result
  already arrived, i.e. the deferred-landing invariant) and reads the settled
  card once its own check completes (desc = "Up to date …"/error, button
  re-enabled, bar 100% or the update card shown); the landing retries while the
  webview is released (the lifecycle closes/reopens the window) and is bounded
  by a 75s timeout; it then runs a second check **in the background** (the
  scheduled path, where Sparkle never invokes the user driver) and reports
  `checkFlowBackground`/`checkFlowBackgroundOk` — an up-to-date outcome must
  land as a success (regression guard: the unclassified `SUNoUpdateError`
  once flipped every hourly check to "couldn't check"); and it runs
  lifecycle checks in
  `lifecycle`: native Settings window open + `settings.json` migration/round-trip
  (`settingsVisible`, `settingsRoundTripOk`), window close keeping backend alive
  while releasing the webview (`closedWindowHidden`, `closedWebReleased`,
  `backendAliveWhileClosed`), window reopen rendering live data (`reopenRenderOk`,
  `reopenMs`), LaunchAgent install/remove round-trip (`daemonRoundTripOk`), and
  boot trace verification (`bootTraceOk`), plus new feature checks: `#mem-pressure`,
  drawer extras (`#dcopy`, `#d-net-box` as `drawerExtrasOk`), Left Panel Energy toggle
  (`energyToggleOk`), Background Items modal (`bgItemsModalOk`), and the row context
  menu — dispatches a button-2 `mousedown` on a visible `#rows-cpu .row` (must open
  `#ctx-menu.on` with items), then a `contextmenu` targeting the open menu itself
  (must NOT close it: WebKit hit-tests that event after the menu is placed under the
  cursor), then a `contextmenu` on `document.body` (must close it; reported as
  `ctxMenuOk`). Renaming those
  DOM ids silently breaks the self-test.
- **Additional inspection & quick-action endpoints**:
  * `GET /api/app-details?pids=1,2,3` — validates up to 80 positive PIDs, runs
    `lsof -nP -a -p <pids> -i -F pcnTP -w` with a 1500ms cache, returning `{ ok, pids, connections }`.
  * `GET /api/background-items` (`?fresh=1`) — scans `~/Library/LaunchAgents`,
    `/Library/LaunchAgents`, `/Library/LaunchDaemons` with `plutil` + `launchctl list`
    + `launchctl print-disabled gui/<uid>` (10s cache).
  * `GET / POST /api/blacklist` — persistent auto-kill rules stored in `~/.pulse/blacklist.json`
    (`action: 'add' | 'toggle' | 'signal' | 'remove'`). Refuses protected system/Pulse processes
    and enforces enabled rules each sampler tick (skipped when `PULSE_SELFTEST=1`).
  * `POST /api/reveal` (`{ path }`) — web-mode fallback allowing only active app bundles/exes
    or `.plist` files in the three LaunchAgent/Daemon dirs; in app mode `Pulse.swift`
    handles `{ action: 'revealInFinder', path }` natively via `NSWorkspace` and
    `{ action: 'copyText', text }` via `NSPasteboard`. `PULSE_AUTOCONFIRM=1` makes the `WKUIDelegate` auto-approve
  `confirm()` dialogs so the test can run unattended.
- **confirm() dialogs**: WKWebView returns false for confirm() unless a
  WKUIDelegate handles it — Pulse.swift renders native NSAlerts (without this the
  kill / quit buttons appear to do nothing). In web mode the browser's own dialogs
  are used.
- **Update availability (Sparkle ⇄ every UI surface)**: the updater is a raw
  `SPUUpdater` with Pulse's own `QuietUserDriver` (no `SPUStandardUpdaterController`),
  so the app must provide Sparkle 2's config keys itself: `SUFeedURL` +
  `SUPublicEDKey` (feed/EdDSA) and `SUEnableAutomaticChecks` (the Sparkle 2 name —
  the 1.x `SUAutomaticallyCheckForUpdates` legacy mapping is what silently left
  every release without scheduled checks until it was added) with
  `SUScheduledCheckInterval = 3600` (hourly). `Pulse.swift` keeps one
  app-side state, `pendingUpdateVersion: String?` — the newest appcast version
  not yet installed, or nil when up to date. Sparkle's `didFindValidUpdate`
  delegate sets it, but **guarded**: the version is only stored when it is
  *strictly newer* than the installed `CFBundleShortVersionString`
  (`isNewerVersion` in `Pulse.swift`). Sparkle itself compares BUILD numbers
  (`CFBundleVersion` vs the appcast's `sparkle:version`), so a build whose
  marketing version was bumped ahead of its build number (a dev build from a
  release-in-progress) would otherwise advertise "v1.4 available" while already
  *showing* 1.4 — the guard kills exactly that. All four surfaces render from the
  one guarded value via `setUpdateIndicators()`: the thin top strip
  (`updateStrip.isHidden`), the status-menu "Update to vX…" row
  (`StatusController.showUpdateRow`), the native Settings Updates card
  (`SettingsWindowController.syncFromState` — Current/Latest versions +
  "Available" badge, a "Checking…" disabled button while a check runs, an
  orange "Couldn't check" badge after a failed check — a failure must never
  render as the up-to-date stamp — and a green "Up to date · HH:mm" badge from
  the last successful check's time), and
  the dashboard via `pushUpdateToWeb()` →
  `window.__pulseUpdate({ current, available?, checkedAt?, checking, failed?, failedAt? })`
  in `index.html` (non-null `available` shows `#st-update-card` with both
  versions + "Update to vX…"; otherwise `#st-check-card` renders the
  `#st-check-desc` state). Dashboard card check lifecycle: `checking` is true
  while an appcast check is in flight — the card animates its own 3px progress
  bar (ramps to ~92% over 1.1s, holds, completes and fades on a success, stays
  lit orange on `failed`; the ramp is only re-armed on an actual phase change —
  re-renders while ramping must keep the in-flight animation, or the bar
  visibly snaps back to empty — and the success fade is one-shot: re-renders
  while already landed (the 15s age ticker, a modal reopen) must leave the
  faded bar alone, or it pulses back to life every 15s). The bar's slot
  collapses to zero while dark (`.off` class, synced with the opacity in
  `renderCheckCard`) so the card carries no dead space under the row — it
  expands with the ramp and folds back in with the fade), and `QuietUserDriver` **suppresses the stock
  progress window for checks started from the card** (`shell.checkFromWeb`) —
  on a fast appcast fetch it flashed open and closed faster than it could be
  read; checks started from the menu/strip/Settings keep the stock window. A result that
  beats the ramp to the finish is *deferred*: the card keeps showing
  "Checking…" (button greyed) until the 1.1s ramp completes, then text + bar +
  card swap land together in one frame, so the word never says "up to date"
  while the bar is still running. `failed` distinguishes a check that errored
  from one that found nothing — the card says "couldn't check" in orange
  instead of claiming up to date — and `failedAt` (epoch ms of the failed
  attempt, pushed alongside `failed`) backs the "· tried <when>" suffix that
  keeps a stale failure reading as one. Check outcomes are classified in
  `Pulse.swift` from the Sparkle delegate callbacks: `updaterDidNotFindUpdate(_:error:)`
  fires for *every* “no update” outcome — the `SUNoUpdateError` pseudo-error,
  including the routine up-to-date one — so it lands as a *success*
  (`updateCheckFoundNothing()`); a check that never completed (the appcast
  fetch or parse failed, a download died) arrives via
  `updater(_:didAbortWithError:)` and lands as `updateCheckFailed()`. (For a
  background check Sparkle never invokes the user driver, so the delegate is
  the only signal — an unclassified `SUNoUpdateError` would flip every
  successful hourly check to “couldn't check”.)
  `checkedAt` (epoch ms) is stamped by
  `updateCheckFoundNothing()` for *any* completed check that found nothing
  (launch, hourly scheduled, manual) and backs the "· checked <when>" line —
  relative while fresh ("just now", "5m ago"), a clock time once it's an hour
  old ("at 14:32"), date+time once a day old — in both the card and the native
  Settings badge (web mode never receives a push, so the card renders from the
  snapshot's `version` and a check click resolves to an "update checks run
  from the Pulse app" explanation). The stock driver's modal "you're up to
  date" alert is suppressed in `QuietUserDriver.showUpdateNotFoundWithError`
  (real check failures still get the stock error alert). `didFinish` re-pushes
  both settings and update state on every webview (re)load so the dashboard
  agrees with the other surfaces. A *declined* real update keeps its indicators
  until installed (Sparkle re-offers at the next launch; the thin strip is the
  persistent signal).
  **Do not remove the version guard** — it only misbehaves in the mismatched
  build-number case, so it is invisible in ordinary builds and easy to mistake
  for dead code.
- **`/api/purge` (server.js ⇄ index.html)**: `POST`, empty body. Two modes:
  * **app mode** (`PULSE=1`): the server samples `vm_stat`, queues the request
    and advertises `purge: <id>` in `/api/status`. The app shell (which polls
    it every 2s) runs the built-in `purge` via an in-process `NSAppleScript`
    — so the SecurityAgent prompt is attributed to Pulse itself (branded, and
    Touch ID is offered) rather than the osascript helper — then POSTs
    `{ id, ok, cancelled }` to **`/api/purge-result`**.
  * **web mode**: the server runs osascript directly (no app shell exists);
    the prompt is attributed to osascript and is password-only.
  Either way the server re-samples `vm_stat` and responds to the UI's original
  fetch with `{ ok, cancelled, freed, cached, error }` (`freed` = free-pool
  growth, `cached` = filecache + purgeable shrink). The popover button
  `#mem-purge` + status `#mem-purge-status` render the result. Fixed command,
  no user input → safe under the loopback-only invariant; 409 while one is in
  flight. On macOS 26.3+, `authd` requires the bundle to satisfy
  `codesign -R="notarized"` for Touch ID to appear on `system.privilege.admin`
  prompts: notarized builds (`fastlane distrib` / `fastlane release` /
  `./app/build.sh --notarize`) get Touch ID + password fallback, while
  unnotarized dev builds (plain `./app/build.sh`) get a Pulse-branded password
  prompt.
