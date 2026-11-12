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
| `server.js` | Node backend: samples the system every second, groups processes into apps, serves the UI over HTTP + SSE (runs app-spawned or as a `launchd` LaunchAgent) |
| `public/index.html` | The entire UI in one file (vanilla JS + CSS, no build step) |
| `app/Pulse.swift` | Native macOS shell: WKWebView window, background/daemon lifecycle, Settings panel, menu-bar status item, native dialogs |
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
   ├─ GET/POST /api/settings → ~/.pulse/settings.json ←  index.html (web mode fallback)
   ├─ POST /api/kill       → { pid, sig }             ←  index.html (kill / quit buttons)
   ├─ POST /api/purge      → admin-prompted `purge`   ←  index.html ("Purge disk cache")
   ├─ POST /api/purge-result → { id, ok, cancelled } ←  Pulse.swift (in-app prompt)
   ├─ GET  /icons/*.png    → cached app icons
   └─ stdout "PULSE_LISTENING=<port>"                 →  Pulse.swift (when app-spawned)
```

Shared state lives in `~/.pulse/`: `port` (active backend port), `settings.json`
(versioned user preferences), `boot-trace.log` (last 10 launch/reopen timing
traces — stage names + timestamps only), and `icons/` (icon cache). Optional
"Start at login" installs `~/Library/LaunchAgents/local.pulse.monitor.plist` so
the backend stays warm across reboots. Closing the dashboard window hides it to
the menu bar by default and releases the `WKWebView` so WebKit XPC helpers exit.
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
6. **Keep release history** — `fastlane release` adds a GitHub release; never
   delete old releases/tags (the releases page is the public history). The
   appcast carrying only the latest entry is intentional and separate.
7. **Log user-visible changes** — every user-visible change gets a bullet in
   `CHANGELOG.md` under `[Unreleased]` (see the `changelog` skill), and the
   entries are summarized before a release so the "what's new" stays concise.
8. **Never advertise an update that isn't actually newer.** Sparkle compares
   *build* numbers (`CFBundleVersion` vs the appcast's `sparkle:version`), but
   the UI shows the *marketing* version — a dev build bumped mid-release can
   "find" an appcast entry equal to its own displayed version. `didFindValidUpdate`
   therefore stores `pendingUpdateVersion` only when strictly newer
   (`isNewerVersion`), and all four indicator surfaces render from that one
   guarded value (see `docs/contracts.md` → Update availability). The guard only
   bites in the mismatched case, so it looks like dead code — don't remove it.

## Run & test

```bash
node server.js                          # web mode → http://127.0.0.1:8787
./app/build.sh                          # build dist/Pulse.app (needs Xcode CLT + node;
                                        #   auto re-notarizes if the previous build was)
./app/build.sh --notarize               # force notarize & staple (needed for Touch ID on Purge)
open dist/Pulse.app
# Self-test (needs a GUI session): renders the page, opens the drawer, checks
# confirm() wiring + the menu-bar item, prints SELFTEST: {...} and exits:
PULSE_SELFTEST=1 PULSE_AUTOCONFIRM=1 dist/Pulse.app/Contents/MacOS/Pulse
# Unit tests (off-line, no macOS dependencies):
node server.test.js              # 136 parser unit tests — fast feedback loop
```

The self-test verifies: the page rendered (machine/cpu/mem populated), rows exist,
the drawer opened (prow count > 0), confirm() is wired, the memory info popover
opens and renders (wired/compressed/cache values + WebKit XPC note), the menu-bar
status item is receiving samples, window close keeps the backend alive while
releasing the webview, window reopen re-renders live data, the Settings dialog
migrates/round-trips `settings.json`, the LaunchAgent install/remove cycle works,
and a real update check through the card button settles correctly — including a
second, *background* check (the scheduled path): an up-to-date outcome must land
as a success, not “couldn't check".

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

## Local work artifacts — `.work/` (gitignored — never commit)

`.work/` is the local-only workspace: task briefs (`.work/briefs/`), screenshots
(`.work/screenshots/`), measurement baselines (`.work/baselines/<date>/`), personal
reference notes (`.work/notes/`). It may contain this machine's data (app names,
paths) — put new working artifacts there, not in `docs/` (which is tracked and
shared). See `.work/README.md` for the layout. Personal (cross-project) agent
skills belong in the user-level skills dirs (`~/.agents/skills/`,
`~/.claude/skills/`) — not in the repo and not in `.work/` (no tool auto-loads
from there); the only repo-tracked skill is `.agents/skills/changelog` (the
release contract, invariant 7).
