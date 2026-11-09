# Changelog

All notable changes to Pulse, newest first.

This file is the source of each release's **"what's new"**: at release time the
Fastfile turns the **Unreleased** section into the Sparkle release notes (shown
in the auto-update dialog), then resets the section to a fresh empty bucket.
Add a bullet under **Unreleased** whenever you ship something user-visible.

## [Unreleased]

### Fixed
- Lighter background menu-bar footprint: when the dashboard window is closed, the sampler reads system CPU counters in-process instead of spawning `top`/`iostat` on every tick, and status-bar views skip redundant redraws when metrics are unchanged

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
