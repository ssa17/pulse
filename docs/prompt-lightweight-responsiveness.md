# Task brief: make Pulse instant to open, keep its data alive in the background, and make it lightweight

> This is a self-contained prompt for an AI agent working in this repo.
> **Read first:** `AGENTS.md`, `docs/contracts.md`, `docs/gotchas.md` (all short, all binding).
> All "measured" figures below were captured on one machine: MacBook Pro, Apple M4 Max, 64 GB, **16 cores,
> macOS 27.2 (26B123), node v26.13.0 (Homebrew)**, **800 processes / 599 app groups**, warm page cache,
> Pulse v1.1 (`server.js` 44 KB, `public/index.html` 56 KB).
> Re-measure on your machine before and after your changes; use the *ratios* as the guide, and paste your numbers.
> Record your own node + macOS versions in the baseline — the daemon-footprint figures depend on the
> node major version (V8), so a different node gives different absolute numbers.
> **Hand-off:** the agent works in *this repo on this machine* (Gemini via Antigravity) — every path in
> this brief (this file, the images in `docs/screenshots/`) can be opened directly. The images are the
> ground truth for what the product looks like and for the §2.3 finding; the §2.6 textual description
> is the equivalent for text-only flows.

---

## 1. Product intent

The user wants Pulse to be **fast, responsive, and lightweight**:

1. Opening the dashboard should show real data **almost instantly** — even right after boot (the "cold start" case they find broken today).
2. The **data should keep running in the background** (the UI is disposable; the sampler is not).
3. The whole thing should use **as little RAM/CPU as possible**. App *distribution size* matters less (see §3.3 — it is already tiny).
4. The user asked whether the implementation language (Node.js) is the problem and whether it "should have been Rust". The honest answer is in §3.4 — read it; it determines what Phase 3 is allowed to be.

The product must keep everything it does today: per-second sampling, app grouping, drill-down drawer, kill/quit buttons, purge-with-Touch-ID, menu-bar CPU+memory bars, Sparkle auto-update, the `node server.test.js` parser suite, and the `PULSE_SELFTEST` self-test.

---

## 2. Current state (measured, v1.1)

### 2.1 Architecture

Three components, one process tree (see AGENTS.md data-flow diagram):

- `server.js` — zero-dependency Node backend. Shells out every second:
  `ps` ×2, `vm_stat`, `sysctl`, `pmset`, `top -F -l 2 -n 2000 -o mem`, `iostat -d -c 2 -w 1`,
  `netstat -ib` (background, ~5s cadence), `system_profiler` (once, background).
  Serves `index.html` + SSE `/events` + `/api/status` + `/api/kill|purge` on 127.0.0.1.
- `public/index.html` — the whole UI (vanilla JS, one 56 KB file). Connects to `/events`, renders rows.
- `app/Pulse.swift` — native shell: WKWebView window + menu-bar `NSStatusItem` (polls `/api/status`
  every 2s) + Sparkle updater + native confirm/alert/prompt dialogs.

Env vars you will use (full list in the README): `PULSE=1` (app mode), `PORT` / `PULSE_PORT`,
`PULSE_NODE` (node binary override), `PULSE_VERSION`, `PULSE_SELFTEST=1`, `PULSE_AUTOCONFIRM=1`,
`INTERVAL`, `HOST` (must stay 127.0.0.1).

**Lifecycle today (this is the core problem):**

- On launch, `startServer()` reuses a running backend via `~/.pulse/port` **if** it is alive, else
  `spawnBackend()` execs a system `node` binary (`findNode()`: `PULSE_NODE` → `/opt/homebrew` → `/usr/local`
  → `/usr/bin` → newest nvm → `/bin/zsh -lc "command -v node"`) with `PULSE=1 PORT=0`, and reads the
  `PULSE_LISTENING=<port>` stdout line before it loads the page (`beginService()`).
- `applicationShouldTerminateAfterLastWindowClosed` returns **true**, and `applicationShouldTerminate`
  kills the spawned node. **Closing the window (or quitting) kills the backend. Data does not survive.
  Every launch pays the full cold-start tax again.** There is no launchd/daemon mode, no "start at login".
- The node backend has an orphan watchdog (exits if its parent dies; already skips itself when `ppid == 1`,
  i.e. launchd — keep that branch correct).
- `~/.pulse/` holds the port file + icon cache + `settings.json` (currently a dead leftover,
  `{"statusBarGraphType":"bars"}`, from the removed sparkline view — Phase 1 turns this into the
  versioned settings store; keep unknown keys intact until then).

### 2.2 Bundle / download size (already small — do not chase this)

| Item | Size |
|---|---|
| `dist/Pulse.app` on disk | **3.7 MB** |
| release zip (`releases/Pulse-1.1.zip`) | **1.32 MB** |
| ├─ Sparkle.framework | 2.9 MB (**78% of the binary**) |
| ├─ Updater.app | 344 KB |
| ├─ `Pulse` (Swift shell binary) | 220 KB |
| └─ server.js + public/ + icon | ~180 KB |

Node is **not bundled** — it is resolved from the user's system at launch (see 2.1). So distribution
size is a non-issue; the practical "size" problems are the **RAM** (§2.3) and the **node dependency**
(a machine without node gets a fatal "install Node.js" dialog).

### 2.3 RAM footprint, measured while the app is open and idle

Physical footprint (`top -F -l 1 -stats pid,mem`) / RSS:

| Process | Footprint | RSS |
|---|---|---|
| `Pulse` (Swift shell) | 34 MB | 126 MB |
| `Pulse` (node backend, `--max-old-space-size=192`) | **114 MB** | 154 MB |
| WebKit WebContent (the UI page) | **112 MB** | 161 MB |
| WebKit GPU | 31 MB | 53 MB |
| WebKit Networking + helpers | ~10 MB | ~33 MB |
| **Total, app open** | **≈ 300 MB** | ≈ 500 MB |

Where it comes from: the node daemon (114 MB) and the WebKit WebContent process (~112 MB, which is
basically WebKit's floor for *any* page) are the two giants. The Swift shell itself is light.

**Finding — the dashboard under-reports Pulse's own cost (confirmed live):** the user observed that
Pulse's *own dashboard* shows the Pulse card at ~150 MB, while Activity Monitor shows several
Pulse-related processes over 100 MB and one over 200 MB. Verified on the live system: the dashboard
Pulse card is **151 MB** (node backend 113 + app shell 34 + sampling children), but the WebKit
processes that actually *render the dashboard* — `com.apple.WebKit.WebContent` **132 MB**,
`com.apple.WebKit.GPU` 28 MB, `com.apple.WebKit.Networking` 17 MB — are **not** in the Pulse group.
True cost of Pulse with the window open ≈ **328 MB** (the card misses ~50%).

Root cause: WebKit helpers are **XPC services reparented to launchd (`ppid = 1`)** — `pgrep -P <app>`
returns only the node backend — so `groupOf()`'s 8-level parent walk can never reach `Pulse.app`
(their exe lives in `WebKit.framework/…/XPCServices/…`, not in a `.app`). They group as *system*
processes, and the `KNOWN` map even labels WebContent "Safari — web page process" (misleading in
Pulse's case). This attribution gap is inherent (no marker identifies which app owns a WebContent
process), so: **do not hack attribution to inflate the Pulse card.** Instead (1) note it in the in-app
memory popover ("Pulse's WebKit rendering processes appear separately in Activity Monitor"), and
(2) make all Phase-2 footprint targets count the **entire** tree via `top`/`ps` — including the
unattributed WebKit XPC processes — never the dashboard's own Pulse figure.

**Evidence (attached):** `docs/screenshots/activity-monitor.png` — Activity Monitor searching
"pulse", sorted by Memory. The six rows *are* the whole tree: WebContent is labelled by its page
URL (`http://127.0.0.1:49551`, 132 MB), the node backend and the shell both show as `Pulse`
(114.5 + 34.1 MB), and the remaining WebKit XPC services appear as `Pulse Networking` (36.5),
`Pulse Graphics and Media` (27.7) and `AutoFill (Pulse)` (10.9) — ≈356 MB in this later sample.
This is exactly the "several over 100 MB, one over 200 MB" the user saw, versus the dashboard's 151.
**The dashboard screenshot shows the same gap in its own panel** (`docs/screenshots/dashboard.png`):
in Top Memory, the Pulse row reads **159 MB** (7 processes) while its own WebKit renderers list
separately in that very panel — `com.apple.WebKit.Web…` (WebContent) **214 MB**, `com.apple.WebKit.GPU`
**293 MB**. Treat the open-mode total as a **330–360 MB envelope** (the two samples are minutes apart;
the WebKit tree drifts ±20 MB with SSE churn) — don't chase the 328-vs-356 difference.

### 2.4 Sampling cost

Warm-cache timings on the reference machine: node spawn → first real snapshot **0.49 s**;
`top -l 1` 0.43 s, `top -l 2` 1.34 s (1 s window by design), `ps` 0.03 s, `system_profiler` 0.08 s.
Snapshot JSON is **338 KB per second** at this machine's load (dominated by per-process `args`
strings across 800 procs) — trivial on loopback, but note it for the Phase-2 payload trim.

### 2.5 Why the dashboard "sometimes takes a long time" on cold start

The code path is: `applicationDidFinishLaunching` → (main-thread: window, WKWebView, menus, Sparkle
init, status-item init) → `startServer()` → `serverIsAlive()` → `spawnBackend()`/`findNode()` →
`PULSE_LISTENING` on stdout → `beginService()` → `web.load()` → WebKit spawns WebContent+GPU XPC
processes → page JS connects to `/events` → first SSE snapshot → first render of real numbers.

Suspects, in suspected importance order — **instrument, don't guess** (Phase 1 item 2):

1. **Nothing is warm.** After boot, *every* step is cold: node's first dyld/V8 page faults, WebKit's
   first WebContent/GPU launch, `top`'s first run. There is no persistent data to display, so the
   empty skeleton stays until the whole chain completes. This is the main event.
2. **`serverIsAlive()` blocks the main thread** — synchronous `URLSession` + `DispatchSemaphore.wait`
   (1.5 s request timeout, 2 s semaphore cap) during launch. A stale or suspended server on the port
   (e.g. a node process from a force-quit prior session that macOS has App-Nap-suspended) burns the
   full 2 s before `spawnBackend` even begins.
3. **`findNode()` may exec `/bin/zsh -lc`** — a *login shell* whose rc files can take seconds on some
   machines. It is the last-resort path, but "sometimes" is exactly what a slow rc file is.
4. **Sparkle** starts its updater in `applicationDidFinishLaunching` (`startingUpdater: true`) —
   usually backgrounded, but verify with the trace that it contributes nothing to the critical path.
5. **First snapshot latency** — fast path is `top -l 1` (~0.4 s warm); on a cold page cache and a
   loaded machine it is worse. The UI correctly paints the skeleton in parallel, so this is a
   first-data delay, not a paint delay.

Note the warm case is already good (≈1.5–2 s end to end on the reference machine); the user's
complaint is the **cold** case, and the structural cause is 2.1/2.5.1: **data dies when the app dies**.

### 2.6 Visual reference (both images exist in `docs/screenshots/` — open them)

- **`docs/screenshots/activity-monitor.png`** — the §2.3 evidence above; also orients the agent on
  what a user sees when they check "how much is Pulse costing me".
- **`docs/screenshots/dashboard.png`** — present (added by the user, 2026-11-06); it is gitignored —
  **never commit it** (it shows the user's own apps). If it goes missing, recapture in a GUI
  session: find the window id (a small `CGWindowListCopyWindowInfo` snippet, or interactive
  `screencapture -i`), then `screencapture -x -o -l<id> docs/screenshots/dashboard.png`.
  **TCC gotcha:** without Screen Recording permission, `screencapture` returns only the window frame
  — the WKWebView content comes back as a dark, empty rectangle (verified: it is the permission,
  **not** the app; do not report a "blank dashboard" from such a capture).
- **What the dashboard shows** (textual equivalent, verified against the screenshot): dark
  single-window dashboard — header: orange dot + "Pulse v1.1", machine line
  ("MacBook Pro · Apple M4 Max · 64 GB · 16 cores"), uptime + battery; a row of four system cards:
  **CPU** (orange, big % + user/sys + sparkline), **MEMORY** (blue, big % + "X of Y GB" + ⓘ +
  4-segment bar + legend with live values: Apps / Wired / Compressed / Cache), **NETWORK** (green,
  big B/s + ↓/↑ + sparkline), **DISK** (purple, big MB/s + "read + write" + sparkline); a toolbar
  with search (⌘F), "N processes · N apps", and a green **live** dot ("reconnecting…" when stale);
  two side-by-side panels **TOP CPU** ("share of N cores") and **TOP MEMORY** ("share of total RAM") —
  each row: icon, name, kind badge (app/system), "N processes · user", bar, figure, per-row sparkline;
  a "show all N" footer; right-click a row for kill/quit; clicking a row slides in a drawer with the
  app's process table (pid, cpu, mem, …). The **ⓘ** opens the memory popover ("Your RAM, in plain
terms": Wired / Compressed / File cache, each with a sparkline, a plain-English explanation, and
  the "Purge disk cache" button). The **menu-bar item** is a small pair of vertical capsule bars
  (orange CPU, blue MEM) with a dropdown menu (CPU / Memory / Top CPU / Top Memory / Open Pulse /
  Quit Pulse).

---

## 3. Answers to the user's questions (the reasoning you must respect)

### 3.1 "I thought we made it fast?"

You made the *warm* path fast (fast first sample, background netstat, no-store cache busting,
parallel page load). The *cold* path was never addressed, because the architecture forces a cold
start on every launch — the backend dies with the window.

### 3.2 "Shouldn't it run in the background — at least the data?"

**Yes — this is the highest-ROI change in this brief.** Two layers:

- **Layer A (required):** the app must not die when the window closes. The menu-bar item *is* the
  always-on component; the window is on-demand. Close → hide window, keep app + backend + graph.
  Re-open → `web.load()` against a live server whose last snapshot is < 4 s old → instant.
- **What closing does — decided (user, 2026-11-06): keep running in the background.** This is the
  macOS convention (most apps stay alive after their window closes; quitting is the explicit
  Cmd-Q / menu action), and it is *necessary* for the instant re-open: killing on close would make
  every re-open pay the cold-start tax again — the exact problem this brief exists to fix. A full
  stop remains available as explicit actions ("Quit Pulse", and "Quit Pulse & Stop Background" when
  the daemon is active). Since the user wants control over behaviour, both options are exposed in
  the new **Settings** dialog (Phase 1 item 3), default = keep in background.
- **Behaviour today → target:**

  | Action | Today | Target |
  |---|---|---|
  | Close window | app quits, backend killed, data dead | window hides; menu-bar item + backend survive |
  | Re-open | full cold start (node + WebKit + first samples) | ≤ 500 ms against the live server |
  | Cmd-Q / menu Quit | kills everything | same explicit full stop (+ "Quit Pulse & Stop Background" when the daemon is active) |
  | Reboot | nothing runs until the app opens | login agent starts the sampler at boot; opening the app already has data |
  | Second launch | reuses running backend via port file | unchanged (`serverIsAlive` gate) |
- **Layer B (required, the real cold-boot fix):** a **"Start at login"** option that installs a user
  LaunchAgent (`~/Library/LaunchAgents/local.pulse.monitor.plist`, `RunAtLoad` + `KeepAlive`) running
  the backend. After boot, the *data* is warm minutes before the user opens the app; opening the app
  then goes through the existing port-file reuse path and the dashboard has real data immediately.
  The existing `serverIsAlive`/port-file/mtime machinery already does the right discovery — extend,
  don't replace it.

### 3.3 "Can we reduce the app size / RAM?"

- **Distribution size:** no — 1.3 MB zipped, and the user confirmed (2026-11-06) that Sparkle's
  2.9 MB is fine: auto-update is a feature worth it (it runs only at deploy/upgrade time, so its
  *runtime* cost is ~nil; the cost is a constant in the bundle). **Keep Sparkle; the size lever is
  closed — do not propose removing or gating it.**
- **RAM:** yes, meaningfully — see Phase 2. Two levers exist in the current stack: the node daemon's
  heap, and making sure WebKit's WebContent process actually goes away when the window closes
  (verify it does today; if the webview is retained, that 112–132 MB never leaves — and per §2.3 it
  is invisible in Pulse's own dashboard, which is exactly why the user saw the Activity-Monitor
  discrepancy).

### 3.4 "Should it have been Rust?"

**No — not as an explanation for what the user is feeling, and not as a Phase-1 fix.**
The measured cold start is dominated by (a) the lifecycle (everything restarts from zero),
(b) WebKit's own cold process launch, and (c) the 8 system tools the sampler shells out to.
Node's own startup is 0.09 s warm; the sampler's time is spent inside `top`/`iostat`/`ps`, which
exist in *any* implementation. A native rewrite fixes none of (a)–(c); it only fixes **RAM**
(node daemon ~114 MB → a native sampler can be < 25 MB) and **portability** (no `node` required →
no findNode dialog, no Homebrew dependency).

So: Phase 1–2 must be done **in the existing Node stack** (they are lifecycle/measurements, and
they stand on their own). A native sampler is **Phase 3, optional, behind an explicit gate** (§4.3)
— and if done, it must still shell out to `top -F -l 2` for per-process `phys_footprint` (see
`docs/gotchas.md`: `task_for_pid`/`task_info` are entitlement-gated; `top` is the one userland
source of the Activity-Monitor number, and of `kernel_task`). Pick Rust *or* Swift and justify in
your PR description (Swift reuses the existing `swiftc` pipeline; Rust yields the smallest static
binary — either must target arm64-apple-macos13+ like the current build).

**Scale of the win — honest framing (user asked 2026-11-06: "114 → <25 MB sounds like a huge
improvement?"):** yes, *for the daemon*: ≈90 MB less on the one process Phase 1 turns into an
all-day background resident (background mode ≈ 150 MB → ≈55–60 MB). But with the window **open**,
WebKit's floor (~112–132 MB) still dominates, so the total open footprint only drops ≈330 →
≈220–240 MB (~25–35%) — the "5×" framing applies to the daemon alone, never to the open app.
The user has **pre-confirmed the direction**, so the Phase-3 gate (§4.3) is satisfied in advance;
the only escape hatch is measured reality (if the tuned Node daemon already sits ≤ 60 MB, the win
is small — report it and stop).

---

## 4. Requirements

### Phase 1 — Data lives in the background; opening is instant (required)

1. **Window ≠ quit — decided (user, 2026-11-06): closing the window keeps Pulse running in the
   background** (the macOS convention; see §3.2). The window hides; the app, its backend, and the
   status-item graph keep running — this is what the user will *see* in Activity Monitor with the
   window closed, and it is the intended behaviour, not a leak. Quitting is always the explicit
   action. The status-item menu must then carry: `Open Pulse`, `Quit Pulse`, plus (when a
   LaunchAgent daemon is active) **"Quit Pulse & Stop Background"** (`launchctl bootout` + exit),
   and the start-at-login toggle (item 5). The close-vs-quit behaviour is user-selectable in the
   Settings dialog (item 3); the *default* must be keep-in-background, and
   `applicationShouldTerminateAfterLastWindowClosed` must read the setting. Decide and document the
   activation policy (`.regular` vs `LSUIElement`): the lowest-risk choice is keeping `.regular`
   (Dock icon doubles as the re-open affordance and preserves the single-instance behaviour); if you
   choose `LSUIElement` instead, you must cover app discovery (Spotlight/`open -a`) and the
   purge-prompt attribution (an agent app must still be able to raise the SecurityAgent dialog —
   verify, don't assume).
2. **Instrument the cold start, then de-risk it.** Add a startup trace: timestamped stages
   (app launch → node spawn → `PULSE_LISTENING` → first snapshot; in the page: DOMContentLoaded →
   first SSE message → first render), **persisted to `~/.pulse/boot-trace.log`** (append per launch,
   keep the last ~10, **stage names + timestamps only — never process names/args (privacy)**) so the
   reboot capture (A3/A4) can run unattended, plus a `/api/status` echo if convenient. Then,
   measured, fix what the trace shows. Known suspects (§2.5): make
   `serverIsAlive` **asynchronous** (no main-thread semaphore; proceed in parallel, 1 s cap), and
   keep the `zsh -lc` lookup off the critical path (measure it; if slow on your machine, reorder or
   drop it). The UI must show a proper connecting-skeleton the instant the page paints.
3. **Settings dialog (user request: "let the user customise how the app behaves").** A small
   settings window, openable from the app menu **and** the status-item menu (native AppKit panel or
   a webview route — your pick; if webview, it must work while the dashboard window is closed).
   Three settings, all applied immediately on toggle (no Apply button) and persisted in
   `~/.pulse/settings.json` **with a `version` field** (migrate the dead `statusBarGraphType` key —
   keep unknown keys, never drop user state):
   1. **Start at login** — on/off; drives the LaunchAgent `bootstrap`/`bootout` (item 5). Default
      **off**. The toggle must reflect *actual* state (read `launchctl list` / the plist file, not
      just the stored preference).
   2. **When the window is closed:** "Keep running in the background (menu bar)" (**default**) /
      "Quit Pulse" (§3.2; this is what `applicationShouldTerminateAfterLastWindowClosed` returns).
   3. **Keep dashboard in memory when closed** — default **off**. Off: releasing the webview lets
      the WebKit tree (≈110–130 MB, §2.3) exit; re-open does a fresh page load (≤500 ms — the A5
      target is measured with it **off**). On: page + SSE stay warm, re-open is instant, at a
      ≈110–130 MB cost while closed (this is the user-facing dial on the A5-vs-A6 tension).
   All three must be visible from the status-item menu as quick actions too (checkmarks), since
   the window may be closed.
4. **Wake/sleep:** keep the existing recovery (App-Nap `beginActivity`, `didWake` → `status.poll()` +
   `window.__pulseWake`, 4.5 s freshness watchdog) working across the new lifecycle — re-verify in
   the self-test.
5. **Start at login (LaunchAgent daemon).** The "Start at login" setting (item 3) installs a user
   LaunchAgent (`~/Library/LaunchAgents/local.pulse.monitor.plist`, `RunAtLoad` + `KeepAlive`) running
   the backend. After boot, the *data* is warm minutes before the user opens the app; opening the app
   then goes through the existing port-file reuse path and the dashboard has real data immediately.
   The existing `serverIsAlive`/port-file/mtime machinery already does the right discovery — extend,
   don't replace it. The plist runs `node <server.js>` with `PULSE=1` (the `ppid == 1`
   orphan-watchdog branch already handles daemon parenting). Handle these edges — they are real:
   - **Sparkle upgrade:** after an auto-update the *old* daemon keeps running the *old* bundle's
     `server.js`/`public/` while the new app starts → two backends / stale UI. On update-complete,
     the app must `bootout` + `bootstrap` the daemon (or re-exec it) so it runs the new bundle,
     then the normal port-file reuse path takes over.
   - Port-file collision between a daemon and an app-spawned backend (only one may own the port;
     the app must not spawn a second backend when the daemon is healthy — `serverIsAlive` already
     decides this; keep the mtime freshness check).
   - `launchctl` failures (agent already loaded, different user session, SSH session with no GUI) →
     fail gracefully with a menu status, never a crash.
6. **Self-test** (`PULSE_SELFTEST=1`) must grow lifecycle checks: window close → backend still
   alive + port file present; window re-open → first real snapshot arrives (existing render checks
   still pass); daemon install/remove round-trip; settings dialog opens and a toggle round-trips
   into `~/.pulse/settings.json`. Keep every existing check green.
7. **Traps specific to this work (verify, don't rediscover):**
   - **Single-instance guard is by bundle id** (`local.pulse.monitor`) and shared by *every* build —
     if any Pulse is running (including the user's own installed one), `open dist/Pulse.app` or the
     self-test will just focus the existing instance and exit. Quit all instances before GUI
     verification; expect the guard to eat your test launches otherwise.
   - **A live user session owns `~/.pulse/port`** and its dynamic port; a dev launch will *reuse*
     their backend (by design). For isolated tests use the `PULSE_SELFTEST=1` path or a forced
     `PULSE_PORT`.
   - **GUI vs headless:** the self-test needs an active GUI login session (WKWebView + SecurityAgent).
     From SSH/CI you can still run `node server.test.js` and web-mode `node server.js`; for the app
     self-test, have the user run it (or `launchctl asuser <uid>` where available). Don't block on it.
   - **Keep `window.isReleasedWhenClosed = false`** when making close≠quit — the window is hidden,
     never deallocated (re-open must not recreate webview state by accident).
   - **WKWebView screenshots are TCC-protected** (§2.6) — a "blank" capture from an unprivileged
     session is the permission, not a regression.
   - **`NODE_OPTIONS=--max-old-space-size=192` is set only on app-mode spawns** (Pulse.swift);
     web-mode dev runs use V8's default heap. Measure with the app-mode flag, since that is the
     shipped configuration.

### Phase 2 — Footprint & CPU hygiene (required, small)

Measure first, tune second; paste before/after numbers:

1. **Steady-state with the window closed** (menu-bar mode): report per-process footprint with
   `top -F -l 1 -stats pid,mem`; confirm the WebKit WebContent/GPU/Networking processes actually
   exit when the window closes (release the webview if they don't). Target: **≤ 150 MB total**
   (today's tree would be node 114 + shell 34 + helpers ≈ 160).
2. **Node daemon:** report steady footprint + V8 heap (`process.memoryUsage()` via a debug field if
   you add one). The `--max-old-space-size=192` cap is a ceiling, not a target — measure the real
   heap and set a justified value; also check the 338 KB/s snapshot serialization isn't driving
   churn (e.g. cap `args` length in the payload *if* the UI doesn't need the full string — it
   currently shows it in the drawer; if it does, leave it and say so).
3. **Idle CPU** of the daemon (mean over 60 s, idle machine): report; target **≤ 3%** and
   document the per-tick exec count. Don't break the 1 s cadence for CPU's sake — that is the product.

### Phase 3 — Native sampler (direction pre-confirmed; gate in the text below)

Gate: pre-confirmed by the user (2026-11-06 — "114 → <25 MB sounds like a huge improvement?" —
and the direction is agreed; see §3.4 for the honest open-mode math). Proceed once Phase 1–2 land
and their acceptance is green; the only stop condition is a tuned Node daemon already ≤ 60 MB
(report it and stop). If (and only if) triggered:

- One static binary, Rust *or* Swift (your pick, justified), arm64-apple-macos13+, **no runtime
  dependency** (delete `findNode()` and the fatal dialog; bundle it into `Contents/MacOS` alongside
  or *instead of* the Swift shell — the shell can become a thin launcher, or the sampler can be a
  second binary the shell spawns; keep the single-instance + port-file + `PULSE_LISTENING` protocols
  exactly as in `docs/contracts.md`).
- **Same HTTP surface and same snapshot/`/api/status` schema** — the UI and the menu-bar item must
  not change a line. `docs/contracts.md` stays true.
- Sampling: direct syscalls for what node reads via exec (`proc_listallpids`/`proc_pidinfo` for
  processes, `host_statistics64`/vm stats, `sysctlbyname`, `getifaddrs` for net, IOKit for disk) —
  **but still shell out to `top -F -l 2 -n 2000 -o mem -stats pid,cpu,mem` for per-process
  phys_footprint + `kernel_task`** (entitlement constraint, `docs/gotchas.md`; its 1.3 s cost is
  inherent and stays, so design the tick so it never blocks the 1 s cadence the way netstat doesn't).
- Port the parser suite: the 136 tests in `server.test.js` (as of v1.1 — count fresh; AGENTS.md
  carries a stale figure) + every quirk in `docs/gotchas.md`
  (two-block iostat, per-address netstat rows, human-scaled top values with delta markers, page
  size, header-reprint on `-l 2`…) must pass against the new implementation or get a documented,
  explained exception.
- Footprint target: daemon **≤ 25 MB**; app bundle growth must be reported (static binary size) —
  if it exceeds ~2 MB, justify.
- `Purge`, `kill`, icons, Sparkle (shell stays Sparkle host) all unchanged and verified.

---

## 5. Invariants — do not break (from AGENTS.md; contracts.md is the detailed source)

1. **127.0.0.1-only, no auth** — `/api/kill` is only safe because of this. Never change the default HOST.
2. **`sample()` stays non-blocking** (netstat is the background precedent) and **first sample stays fast**.
3. **Single instance** via bundle id `local.pulse.monitor` — must survive the new lifecycle.
4. **UI row caching** — `renderPanel` reuses DOM rows (`rowEls`); never rebuild per tick.
5. **Memory segments sum to `used`** (normalized in `sample()`).
6. **Releases are history** — never delete releases/tags; the appcast is intentionally latest-only.
7. **Changelog** — every user-visible change gets a bullet under `[Unreleased]` (use the `changelog` skill).
8. **Contracts** — any change to snapshot / `/api/status` / port-file / stdout / self-test protocol
   is a 3-way change (`server.js` ⇄ `index.html` ⇄ `Pulse.swift` + `docs/contracts.md`). The self-test
   DOM ids in `Pulse.swift`'s `beginService` are load-bearing; don't rename ids in `index.html`.
9. **No state inside the `.app` bundle** — it stays immutable and rebuildable (`~/.pulse` is the state dir).
10. **Zero npm dependencies** stays zero.

---

## 6. Definition of done (acceptance — paste evidence for each)

| # | Criterion | How to verify |
|---|---|---|
| A1 | `node server.test.js` | all parser tests pass (136 as of v1.1) |
| A2 | Self-test | `PULSE_SELFTEST=1 PULSE_AUTOCONFIRM=1 dist/Pulse.app/Contents/MacOS/Pulse` → `SELFTEST: {...}` all green, **including the new lifecycle checks** (settings dialog open + toggle round-trip) |
| A3 | Cold boot, daemon **on** | **coordinated with the user — never reboot or log them out yourself** (no `sudo shutdown`/`reboot`); after the reboot: `open -a Pulse`, read `~/.pulse/boot-trace.log` → first real data **≤ 1.5 s**, menu-bar graph **≤ 3 s** (trace pasted) |
| A4 | Cold boot, daemon **off** | same coordination; if the user cannot reboot, approximate (user runs `sudo purge` for the page cache + kill the backend) and **label the result an approximation** until a real reboot confirms it → first real data **≤ 3 s** |
| A5 | Re-open | close window → `pgrep` shows backend alive, `~/.pulse/port` present, and **`curl -s http://127.0.0.1:$(cat ~/.pulse/port)/api/status` returns an advancing `t`** (data genuinely ticking while closed) → re-open window → first paint with data **≤ 500 ms** |
| A6 | RAM, window closed | steady footprint of the **entire** Pulse tree via `top`/`ps` — *including* the unattributed WebKit XPC processes (§2.3); the WebKit tree must be gone by now (window closed ⇒ webview released); reported, **≤ 150 MB** |
| A7 | RAM, window open | reported; **no regression** vs the ~300 MB baseline (WebKit floor dominates — don't chase) |
| A8 | Idle CPU | daemon mean CPU over 60 s idle reported; **≤ 3%** |
| A9 | Size | release zip size reported (expect ~1.3 MB; unchanged) |
| A10 | Changelog | `[Unreleased]` bullets per the changelog skill, summarised at release |
| A11 | Docs | `AGENTS.md` component/lifecycle sections and `docs/contracts.md` updated to the new reality (daemon mode, window≠quit, settings dialog, versioned settings.json schema) |
| A12 | Dashboard honesty | memory popover notes that Pulse's WebKit rendering processes appear separately in Activity Monitor (§2.3 finding) |

---

## 7. Out of scope (do not do, however tempting)

- Removing or gating Sparkle — user confirmed (2026-11-06) the auto-update feature is worth the
  2.9 MB. Bundle-shrinking is still not a goal (§3.3).
- Replacing the WKWebView UI with native AppKit/SwiftUI views (the 112 MB WebContent floor is the
  price of keeping this UI; a native-UI rewrite is a separate project).
- A full rewrite of `server.js` in Phase 1/2 — those phases are lifecycle + measurements in the
  existing stack.
- Raising/lowering the 1 s sampling cadence as a "lightweight" trick (the product is real-time).
- Any change to the release-history / appcast rules.
- **Publishing is a human-only act** — never run `fastlane` (`distrib`/`release`), never create tags
  or GitHub releases, never touch `secrets/`. The agent ships code; the user ships versions.
- **Scope discipline** — implement the phases as written. If you find a genuinely better approach
  that would change a contract, an invariant, or a phase's scope: record it in the final report with
  reasoning and **don't execute it unilaterally**.

## 8. Order of operations

1. Read the three docs, then **take the baselines** (reboot experiment, `top` footprint table, idle
   CPU, node heap) *before changing anything* — every target in §6 needs a before/after. Save them
   to `docs/baseline-<date>/` (gitignored — may contain the user's app list; **never commit**).
2. Phase 1 → 2, each verified against `node server.test.js` + self-test at the end.
3. Report the measured results. Phase 3 is **pre-confirmed in direction** (2026-11-06) — proceed
   after Phase 1/2 acceptance unless the tuned Node daemon already sits ≤ 60 MB (then report and stop).
4. At release: bump the version in **`app/Info.plist` only** (the single source of truth;
   `app/build.sh` syncs package.json) and let the changelog skill summarise the `[Unreleased]`
   bullets — releases/tags are public history (AGENTS.md invariant 6). Do **not** run the release
   itself (see §7) — prepare it and hand the user the exact command.
5. **Final report** — the §6 A-table filled with before/after numbers, then: **Decisions** (each
   choice you made — activation policy, Rust-vs-Swift, webview release vs retain — with a one-line
   rationale), **Deviations** (where you didn't follow this brief and why), **Risks / open items**
   (including any A3/A4 that was only approximated). Close with the **30-second demo script** for the
   user: open app → close window (menu-bar bars keep ticking, `curl /api/status` stays fresh) →
   re-open (instant) → Quit (full stop).
