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
  sys: {
    model, chip, memLabel,      // from system_profiler; null until it finishes loading
    hostname, cores, memTotal,  // memTotal in bytes
    cpu:  { user, sys, idle, total },   // percents; total = 100 - idle
    mem:  { free, used, apps, wired, compressed, cache },  // bytes; apps+wired+compressed+cache == used
    swap: { total, used },      // bytes
    load: [1m, 5m, 15m],
    uptime: <seconds>,
    net:  { down, up },         // bytes/sec
    disk: { mbps },             // MB/s, read + write
    batt: { pct, charging, time },   // pct null when on AC / no battery
    procCount, appCount
  },
  apps: [{
    key, name, kind: 'app' | 'system' | 'other',
    bundle,                    // .app path or null
    icon,                      // /icons/<hash>.png or null
    cpu,                       // % of ALL cores (16 cores fully busy = 100)
    mem,                       // bytes (sum of process RSS)
    procs, users: [..], mainPid,
    processes: [{ pid, ppid, user, name, cpu, mem, vsz, stat, etime, args, role, desc }]
  }]
}
```

## The /api/status shape (server.js ⇄ Pulse.swift)

```js
{ cpu: { user, sys, idle, total },   // SYSTEM cpu (from top) — NOT an app
  memPct, memUsed, memTotal,
  topCpu: { name, cpu },             // top app by cpu
  topMem: { name, mem } }            // top app by mem
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
  `#rows-cpu .row`, counts `#dtable .prow`, and reads `#machine`, `#cpu-big`,
  `#mem-big`, `#live-text` from index.html. Renaming those ids silently breaks the
  self-test. `PULSE_AUTOCONFIRM=1` makes the WKUIDelegate auto-approve confirm()
  dialogs so the test can run unattended.
- **confirm() dialogs**: WKWebView returns false for confirm() unless a
  WKUIDelegate handles it — Pulse.swift renders native NSAlerts (without this the
  kill / quit buttons appear to do nothing). In web mode the browser's own dialogs
  are used.
