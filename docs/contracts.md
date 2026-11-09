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
    cpu:  { user, sys, idle, total, temp }, // percents (total = 100 - idle); temp in °C or null
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
    swap: { used },                // bytes (total is auto-allocated on macOS — not shipped)
    uptime: <seconds>,
    net:  { down, up },         // bytes/sec
    disk: { mbps },             // MB/s, read + write
    batt: { pct, charging },        // pct null when on AC / no battery
    gpu:  { pct, name, cores },      // Apple Silicon only (ioreg AGX); pct null elsewhere.
                                     // pct = delta of accumulatedGPUTime ÷ window ÷ MGPU units;
                                     // name/cores from the GPU node
    thermal: { level, state, cpu, min, max }, // level 0..3 (pmset), state: nominal|slowed|throttled; cpu: temp in °C or null;
                                              // min/max: the machine's observed cold–hot range since the sampler
                                              // started (null until the first reading). The UIs colour the ROUNDED
                                              // temp on a span floored at 10°C so both show the same colour for the
                                              // same number
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
    procs, users: [..], mainPid,   // mainPid is always > 0 or null (PID 0 kernel_task is never killable)
    processes: [{ pid, ppid, user, name, cpu, mem, vsz, stat, etime, args, role, desc }]
  }]
}
```

## The /api/status shape (server.js ⇄ Pulse.swift)

```js
{ t: <ms epoch>,                     // sample completion timestamp
  serverMtime: <sec epoch>,          // mtime of server.js at boot (triggers live backend reload on rebuild)
  bootTrace: { start, listen, firstSnapshot }, // epoch ms timestamps for startup trace logging
  memDebug: { rss, heapTotal, heapUsed, external }, // Node V8 memory telemetry (bytes)
  cpu: { user, sys, idle, total, temp }, // SYSTEM cpu (from top) — NOT an app; temp in °C or null
  memPct, memUsed, memTotal,         // AM-style: memUsed = used − file cache
  gpuPct,                            // Apple Silicon GPU utilization %; null if unavailable
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

- **Port discovery**: the backend writes `~/.pulse/port` on startup and removes it on
  exit (only if the file still points at ITSELF — another live backend may have
  overwritten it since). A new launch (app or web) reuses a
  running backend only if that port answers `/api/snapshot` with a fresh Pulse
  payload matching `serverMtime` (`checkServerAlive` in `Pulse.swift` runs
  asynchronously with a 1.0s cap so it never blocks the main thread). If the
  LaunchAgent daemon is loaded but serving a STALE `server.js` (a rebuild changes
  the code, which the plist doesn't track), the app restarts the daemon
  (`launchctl kickstart -k`) before attaching instead of spawning a parallel
  backend of its own — and when it adopts the daemon it releases any backend it
  spawned while waiting, so exactly one sampler ever runs.
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
  `index.html` log timestamped stages (`app_launch`, `port_probe_start`,
  `daemon_reused` / `backend_spawn`, `pulse_listening`, `webview_load`,
  `dom_content_loaded`, `backend_first_snapshot`, `menubar_first_sample`,
  `first_sse_message`, `first_render`, plus `window_reopen` sessions), keeping
  the last 10 sessions. **Privacy invariant**: only stage names and numeric
  timestamps are ever written — never process names, arguments, or paths.
- **Self-test DOM & lifecycle contract**: with `PULSE_SELFTEST=1`, `Pulse.swift`
  clicks `#rows-cpu .row`, counts `#dtable .prow`, reads `#machine`, `#cpu-big`,
  `#mem-big`, `#live-text`, `#ver` from `index.html`, exercises the memory info
  popover (clicks `#mem-info` → reads `#mempop` open + `#pop-wired`, `#pop-comp`,
  `#pop-cache`, `#pop-webkit-note` → closes it), exercises the in-dashboard
  Settings modal (`#settings-btn` → `#settings-scrim.on` → `#settings-close`,
  reported as `dashboardSettingsOk`), and runs lifecycle checks in
  `lifecycle`: native Settings window open + `settings.json` migration/round-trip
  (`settingsVisible`, `settingsRoundTripOk`), window close keeping backend alive
  while releasing the webview (`closedWindowHidden`, `closedWebReleased`,
  `backendAliveWhileClosed`), window reopen rendering live data (`reopenRenderOk`,
  `reopenMs`), LaunchAgent install/remove round-trip (`daemonRoundTripOk`), and
  boot trace verification (`bootTraceOk`). Renaming those DOM ids silently breaks
  the self-test. `PULSE_AUTOCONFIRM=1` makes the `WKUIDelegate` auto-approve
  `confirm()` dialogs so the test can run unattended.
- **confirm() dialogs**: WKWebView returns false for confirm() unless a
  WKUIDelegate handles it — Pulse.swift renders native NSAlerts (without this the
  kill / quit buttons appear to do nothing). In web mode the browser's own dialogs
  are used.
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
