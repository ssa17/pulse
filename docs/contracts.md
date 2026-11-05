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
    cpu:  { user, sys, idle, total },   // percents; total = 100 - idle
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
  cpu: { user, sys, idle, total },   // SYSTEM cpu (from top) — NOT an app
  memPct, memUsed, memTotal,         // AM-style: memUsed = used − file cache
  topCpu: { name, cpu },             // top app by cpu
  topMem: { name, mem },
  purge: <id> }                      // OPTIONAL — only while a purge is queued;
                                     // the app shell runs the in-process prompt
                                     // and reports via /api/purge-result
```

`Pulse.swift` (`StatusController.poll`) reads exactly: `cpu.total`, `cpu.user`,
`cpu.sys`, `memPct`, `memUsed`, `memTotal`, `topCpu.name/cpu`, `topMem.name/mem`.
Note the confusing naming: `cpu` is the system CPU object; `topCpu` is an app.

## Cross-component protocols

- **Port discovery**: the backend writes `~/.pulse/port` on startup and removes it
  on any exit (signal, orphan watchdog, crash). A new launch (app or web) reuses a
  running backend only if that port answers `/api/snapshot` with a real Pulse
  payload (`serverIsAlive` in Pulse.swift checks for `"apps"` and `"sys"` in the
  body, so a foreign server on the port is not reused).
- **App-spawned backend**: Pulse.swift spawns `node server.js` with `PULSE=1
  PORT=0` (dynamic port) and reads the port from the `PULSE_LISTENING=<port>`
  stdout line. The backend runs an orphan watchdog (exits if its parent dies) and
  the app kills it on quit — three mechanisms, keep them in sync if you change one.
- **Self-test DOM contract**: with `PULSE_SELFTEST=1`, Pulse.swift clicks
  `#rows-cpu .row`, counts `#dtable .prow`, reads `#machine`, `#cpu-big`,
  `#mem-big`, `#live-text`, `#ver` from index.html, and exercises the memory info
  popover (clicks `#mem-info` → reads `#mempop` open + `#pop-wired`,
  `#pop-comp`, `#pop-cache` → closes it). Renaming those ids silently breaks the
  self-test. `PULSE_AUTOCONFIRM=1` makes the WKUIDelegate auto-approve confirm()
  dialogs so the test can run unattended.
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
- **Status-bar graph style** (`Pulse.swift`-only, not shared with the web UI): the
  menu-bar item can render either the classic sparklines or oMLX-style vertical
  capsule bars, toggled from its menu. The choice persists in
  `~/.pulse/settings.json` (`{ "statusBarGraphType": "bars" | "sparkline" }`;
  default is `sparkline`).
