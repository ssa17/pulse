# AGENTS.md — working context for Pulse

Read this before changing anything. It orients you and points to deeper docs.
The README is user-facing; this is for agents. **This file is the always-loaded
entry point, so it is deliberately short** — reference material (schemas, parser
quirks) lives in `docs/` and is read on demand (see the table at the bottom).

## What Pulse is

A real-time macOS resource dashboard: see which apps are eating your CPU and memory,
drill into their processes, kill them. Zero npm dependencies — the whole project is
a handful of source files.

## Components

| File | Role |
|---|---|
| `server.js` | Node backend: samples the system every second, groups processes into apps, serves the UI over HTTP + SSE |
| `public/index.html` | The entire UI in one file (vanilla JS + CSS, no build step) |
| `app/Pulse.swift` | Native macOS shell: WKWebView window, backend lifecycle, menu-bar status item, native dialogs |
| `app/Info.plist` | App metadata (bundle id, local-networking exception, icon) |
| `app/build.sh` | Builds `dist/Pulse.app` (swiftc + sips + iconutil) |
| `app/make-icon.mjs` | Generates the 1024px app icon (pure-Node PNG writer) |

## Data flow

```
macOS: ps · vm_stat · sysctl · top · netstat · iostat · pmset · system_profiler
   │  sampled every 1s by server.js (see "How it reads your Mac" in README)
   ▼
server.js  →  one JSON "snapshot" per tick (schema in docs/contracts.md)
   │
   ├─ GET  /               → index.html (the UI)
   ├─ GET  /events         → SSE stream of snapshots  →  index.html (live updates)
   ├─ GET  /api/snapshot   → last snapshot            →  index.html (polling fallback)
   ├─ GET  /api/status     → lightweight status       →  Pulse.swift menu-bar item (2s poll)
   ├─ POST /api/kill       → { pid, sig }             ←  index.html (kill / quit buttons)
   ├─ GET  /icons/*.png    → cached app icons
   └─ stdout "PULSE_LISTENING=<port>"                 →  Pulse.swift (when app-spawned)
```

Shared state lives in `~/.pulse/`: `port` (port file) and `icons/` (icon cache).
Never store state inside the .app bundle — it must stay immutable and rebuildable.

## Invariants (do not break)

1. **Binds to 127.0.0.1 only, no auth.** `/api/kill` can kill any process; it is
   only safe because the server is loopback-only. Don't change the default HOST.
2. **`sample()` must stay non-blocking.** `netstat -ib` can take seconds on
   machines with many interfaces, so it runs in the background (`kickNetstat`) and
   the network card updates every ~5s. The first sample skips the 1s-window
   commands (top, iostat) so the UI gets real data almost instantly.
3. **Single instance** (Pulse.swift): a second launch focuses the first and exits.
   Relies on bundle id `local.pulse.monitor` in Info.plist.
4. **The UI reuses DOM rows** — one per (panel, app), cached in `rowEls`, hidden
   not removed. Don't "simplify" `renderPanel` to rebuild the DOM every tick.
5. **Memory segments must sum to `used`** — they are normalized in `sample()`
   because RSS double-counts shared pages.

## Run & test

```bash
node server.js                          # web mode → http://127.0.0.1:8787
./app/build.sh                          # build dist/Pulse.app (needs Xcode CLT + node)
open dist/Pulse.app
# Self-test (needs a GUI session): renders the page, opens the drawer, checks
# confirm() wiring + the menu-bar item, prints SELFTEST: {...} and exits:
PULSE_SELFTEST=1 PULSE_AUTOCONFIRM=1 dist/Pulse.app/Contents/MacOS/Pulse
```

The self-test verifies: the page rendered (machine/cpu/mem populated), rows exist,
the drawer opened (prow count > 0), confirm() is wired, and the menu-bar status
item is receiving samples.

## Deep docs — read on demand

This file is deliberately short. Open the matching doc **only when the task needs it**:

| Doc | Read it when you're touching… |
|---|---|
| `docs/contracts.md` | The data that flows between components: the snapshot schema (server.js ⇄ index.html), the `/api/status` shape (server.js ⇄ Pulse.swift), or the port-file / stdout / self-test / dialog protocols |
| `docs/gotchas.md` | Sampling & parsing in `server.js`: ps, iostat, netstat, vm_stat, app-bundle attribution, icon cache |

One-line summaries, so you know what exists without opening them:
- **contracts.md** — the exact JSON field names the UI and the menu-bar item read,
  plus how the app finds / reuses / spawns the backend and how the self-test drives the UI.
- **gotchas.md** — the non-obvious output formats of the macOS tools the parsers
  depend on, and why each parser is shaped the way it is.
