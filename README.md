# Pulse — real-time Mac resource dashboard

See, in real time, exactly which apps are eating your CPU and memory — and manage them.

## Native app (recommended)

```bash
./app/build.sh          # builds dist/Pulse.app (needs Xcode CLT: swiftc)
open dist/Pulse.app     # or double-click it
```

`Pulse.app` is a small native Swift shell (WKWebView) that:
- is **single-instance**: launching it again focuses the existing window instead of
  spawning a duplicate
- **reuses a running backend** via `~/.pulse/port` (works across app ↔ web mode),
  otherwise spawns one on a **dynamic free port** (no fixed port, no conflicts;
  the backend announces its port on stdout and in `~/.pulse/port`)
- kills its backend on quit (plus a watchdog in the backend for abnormal exits)
- shows a **live menu-bar status item** (CPU + memory graphs, like oMLX's) with a menu:
  current CPU/memory, top consumers, Open Pulse, Quit Pulse
- shows up in Activity Monitor as **Pulse** (the backend process is also titled "Pulse";
  the web content runs in WebKit's own "Web Content" process, as with any webview app)
- renders native dialogs for the in-app confirm() prompts (kill / quit-app buttons)

In-app: **Cmd-R** reloads, **Cmd-Q** quits. `PULSE_SELFTEST=1` runs a render +
interaction self-test (with `PULSE_AUTOCONFIRM=1` to auto-approve dialogs) and exits.

**Footprint:** the `.app` is ~350KB on disk (no bundled runtime — it uses your system
Node). At runtime it uses ~300–400MB, most of it WebKit's own processes (the webview
UI); the Node backend is heap-capped to stay lean. Shared state (port file, icon
cache) lives in `~/.pulse/`, never inside the bundle.

**Using it on another Mac** (e.g. a work laptop): copy the `pulse` source folder over
and run `./app/build.sh` there — it compiles for that machine (Intel or Apple Silicon),
needs Xcode Command Line Tools + Node. Copying the built `.app` directly also works,
but as an unsigned app macOS may ask you to right-click → Open the first time.
All data sources (ps, vm_stat, sysctl, top, netstat, iostat, pmset) are standard on
every macOS, so the dashboard works identically on Intel and Apple Silicon.

## Web mode

```bash
node server.js          # → http://127.0.0.1:8787
```

## What you get

- **Top CPU / Top Memory panels** — every process on the machine grouped into its app
  (Chrome's 30 helper processes become one "Google Chrome" row), with real app icons,
  a bar showing the share of your *total* resources, live values, and sparklines.
- **System cards** — CPU (user/sys/idle), memory breakdown (apps / wired / compressed /
  cache / free + swap), network, disk, battery, load, uptime.
- **Detail drawer** — click any app to see every process behind it: what it is,
  its role (web page / GPU / helper…), full command line, CPU, memory, state,
  start time — plus **kill** and **Quit app** buttons.
- **Search** — filter by app name, bundle path, or any process/command.
- Updates every second over Server-Sent Events (auto-falls back to polling), auto-reconnects.

## How it reads your Mac

| Source | Data |
|---|---|
| `ps` (all processes) | per-process CPU (delta of cumulative CPU time → real-time), RSS memory, state, start time, full command |
| `vm_stat` + `sysctl` | memory breakdown, swap, load average, uptime, total RAM |
| `top -l 2` | system CPU user/sys/idle |
| `netstat -ib` | network in/out rates |
| `iostat` | disk read/write rate |
| `pmset` | battery |
| `system_profiler` | machine identity (model, chip, memory) |

**App intelligence:** a process is attributed to an app if its executable lives inside
a `.app` bundle (outermost bundle wins, so nested helper bundles resolve to the real
app), or if any ancestor (up to 8 levels) does — so a `node` process spawned by
VS Code shows up under VS Code. Everything else is grouped by executable name and
tagged `system` or `user`. Common daemons (WindowServer, mdworker, kernel_task, …)
carry a one-line explanation in the detail view.

## Notes

- CPU % is expressed as a share of **all** cores (16 cores fully busy = 100%).
- Memory per app is the sum of process RSS (shared pages can be counted more than once).
- App icons are extracted from the `.app` bundle with `sips` and cached in
  `~/.pulse/icons/`.
- Kill buttons send SIGTERM (SIGKILL available via the API: `POST /api/kill {"pid":123,"sig":"KILL"}`).
- Binds to 127.0.0.1 only.
- Sampling runs every second. `netstat -ib` can take seconds on machines with many
  interfaces, so it runs in the background and the network card updates every ~5s
  (rates are computed over the real elapsed time, so they stay accurate).
- The first sample skips the 1-second-window commands (top, iostat) so the UI gets
  real data almost instantly; they fill in on the next tick.

## Environment variables

| Var | Default | Meaning |
|---|---|---|
| `PORT` | `8787` (web) / dynamic (app) | HTTP port; `0` = OS picks a free one |
| `HOST` | `127.0.0.1` | bind address |
| `INTERVAL` | `1000` | sampling interval (ms) |
| `PULSE` | — | set by the app; makes the backend use a dynamic port + orphan watchdog |
| `PULSE_NODE` | — | explicit path to the node binary (app mode) |
| `PULSE_PORT` | — | force a specific port (app mode) |
| `PULSE_SELFTEST=1` | — | app prints a render + interaction self-test and exits |

## Layout

```
AGENTS.md            short entry point for agents: orientation, invariants, run/test
                     (points to docs/ for the deep material — read this first)
docs/contracts.md    the data contracts between components (schemas + protocols)
docs/gotchas.md      non-obvious macOS tool output formats the parsers rely on
server.js            zero-dependency Node backend (sampling, grouping, SSE)
public/index.html    the dashboard UI (single file, no build step)
app/Pulse.swift      native app shell (WKWebView + backend lifecycle)
app/Info.plist       app metadata (local networking, icon, category)
app/make-icon.mjs    generates the app icon (pure Node PNG writer)
app/build.sh         builds dist/Pulse.app
```
