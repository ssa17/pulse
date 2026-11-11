# Changelog

All notable changes to Pulse, newest first.

This file is the source of each release's **"what's new"**: at release time the
Fastfile turns the **Unreleased** section into the Sparkle release notes (shown
in the auto-update dialog), then resets the section to a fresh empty bucket.
Add a bullet under **Unreleased** whenever you ship something user-visible.

## [Unreleased]
- The thermal state word (nominal / slowed / throttled) is now colored by the actual SMC throttle level — nominal reads neutral instead of red — while the CPU temperature keeps its own green→red ramp, on both the dashboard CPU card and the menu bar

### Added
- Settings: the Updates card now shows your current version and the latest one, with an “Available” badge when a newer build is out
- Dashboard: a live progress bar in the Updates card while an update check runs — it lands on a green “Up to date” with when Pulse last verified your version, or hands off to the highlighted new version — and the brief macOS progress window no longer flashes for checks started from the dashboard

### Changed
- Settings: the Updates card button shows “Checking…” while a check is in flight
- Dashboard: in the browser without the Pulse app, “Check for Updates” now explains that update checks run from the app, instead of doing nothing

### Fixed
- Dashboard: a failed update check now says “Couldn’t check for updates” in the Updates card instead of silently keeping a stale “up to date” claim
- Settings: when you're on the latest version, the Updates card shows “You have vX — up to date” instead of a ghost “New update available” card with empty versions (the card's hidden state was defeated by its styling, so it lingered with placeholder text)
- Settings: a manual update check that finds nothing no longer pops a macOS “you're up to date” dialog you must click OK on — the Updates card confirms it inline instead ("You have v1.4. Up to date · checked just now")
- Dashboard: the updates section re-syncs when the window re-opens, so it always agrees with the menu bar and the app's Settings
- Dashboard: clicking outside the right-click context menu now dismisses it without also triggering whatever is underneath (the dismissing click no longer opens a drawer)

## [1.4] - 2026-11-10

### Added
- Live CPU die temperature (°C) on the dashboard CPU card, coloured green→red by how hot the machine is and flagging throttling, with the same reading pinned just below CPU in the menu bar
- New status-bar dropdown visuals: dual 30s rolling wave graphs for E/P core clusters, GPU utilization vs. GPU memory, live GPU memory in use, system load averages, and a color-coded memory breakdown (Wired, Active, Compressed, Free)

### Changed
- Status-bar dropdown is grouped into clean CPU, GPU, MEMORY, and SYSTEM sections with centered titles and airy spacing
- Update checks now run hourly instead of once a day

### Fixed
- Lighter background footprint: with the dashboard closed, the sampler no longer spawns `top`/`iostat` on every tick, and the status bar skips redundant redraws

## [1.3] - 2026-11-09

### Added
- GPU section: a new GPU card (live utilization, sparkline, chip name) on Apple Silicon, plus a GPU row in the status menu
- Updates are now visible everywhere: a thin green strip along the top of the window, an “Update to vX…” row in the status menu, and a row in Settings — declining is re-offered on the next launch

### Changed
- Status-bar menu redesigned in the style of the Stats app: each stat is a row with a colored utilization bar, and Open Pulse, Settings, and Quit (which also stops the background sampler) are the only actions
- Row order and visibility are configurable in Settings, with a separate switch for which rows appear in the dropdown and which show as button capsules — hiding all of them is a valid layout
- The button's NET capsule shows pinned ↓/↑ arrows with right-aligned figures, using the same B → KB → MB → GB units as the dashboard

### Fixed
- Status-bar menu: clicking the icon again now closes the menu — like every other menu-bar app — and clicking a stat row just closes it
- The button no longer blinks when a stat is toggled in Settings, and settings saved in the dashboard are no longer silently reverted by the app
- After a rebuild, the background sampler restarts onto the new code instead of leaving a second parallel one behind
- The thermal chip on the CPU card only appears when the machine is actually being throttled

## [1.2] - 2026-11-06

### Added
- Background mode & Settings (`⌘,` or the header **Settings** button): closing the window now keeps Pulse sampling in the menu bar by default; customize **Start at login** (runs a background sampler so data is warm right after boot), **When the window is closed**, and **Keep dashboard in memory** from the in-dashboard Settings modal, the native Settings window, or the menu-bar quick toggles
- Memory explainer & "Purge disk cache": click `i` on the Memory card (or any pool in the legend) to see live wired, compressed, and file-cache sparklines and clear reclaimable disk cache via Touch ID or password
- Quick actions & keyboard navigation: right-click any app or process for Quit, Force Quit, Terminate, and Force Kill; press `⌘F` or `/` to search and `Esc` to dismiss menus, popovers, the drawer, or active search
- Process list now includes `kernel_task` alongside other system processes

### Changed
- Much lighter background footprint: releasing the web view on window close and tuning the sampler cuts background RAM to ~80 MB while reopening in under 0.2 seconds
- Redesigned Memory and Network cards: memory figures now match Activity Monitor ("Memory Used", per-app footprint, and Cached Files) with a 2×2 legend, and Network shows combined ↓ + ↑ throughput
- Menu-bar item now always displays compact vertical CPU and memory capsule bars with tighter spacing

### Fixed
- Cold launches show an immediate connecting skeleton without main-thread stalls, and the dashboard and background sampler stay in sync across app updates
- Fixed compressed-memory reporting, CPU card blips after process actions, battery charging-bolt state on AC hold, and right-click text selection

## [1.1] - 2026-11-02

### Changed
- Runs on macOS 13+ (deployment target pinned — previously the app only ran
  on the macOS version it was built with)

## [1.0] - 2026-11-01

### Added
- Initial public release: live CPU / memory / network / disk dashboard,
  per-app drill-down with process list, kill / quit, menu-bar status item,
  Sparkle auto-updates
