# Changelog

All notable changes to Pulse, newest first.

This file is the source of each release's **"what's new"**: at release time the
Fastfile turns the **Unreleased** section into the Sparkle release notes (shown
in the auto-update dialog), then resets the section to a fresh empty bucket.
Add a bullet under **Unreleased** whenever you ship something user-visible.

## [Unreleased]

### Added
- GPU section: new GPU card (live utilization, sparkline, chip name) sampled root-free from `ioreg` on Apple Silicon; the status menu gained a GPU row
- Status-bar menu gained Thermal and Uptime rows (hidden by default, restorable in Settings)
- **Network joins the status menu** as a row (on by default) with a purple `NET` capsule on the button — the data is the existing per-interface netstat rates summed, no new sampling
- **Update availability, everywhere and quietly**: when a version check finds an update, a very thin green strip runs along the top of the window (click = install), the status menu grows an “Update to vX…” row, and Settings (both dashboard and native) show an “Update available — v…” row with a button. Declining the sheet re-offers on the next launch, and the strip stays as a persistent marker until the version actually changes; a failed check leaves the previous state untouched

### Changed
- Status-bar menu redesign, in the style of the Stats app: values at the row's end with a colored utilization bar beneath each; removed the version header, the settings toggles, and the Top CPU / Top Memory rows — Open Pulse, Settings, and Quit (which also stops the background sampler) are the only actions
- Status menu: the Memory row reads `30.6 GB / 64 GB · 24%` (no "of"); row order and visibility are configurable in Settings (drag to reorder, or the switch / ↑↓), Thermal hidden by default, all six rows (incl. Network) always listed; hiding a row keeps its slot, and hiding all rows is a valid layout
- **Separate controls for the status bar and the status menu**: Settings ("Status bar & menu") has a labeled switch per stat per surface — each toggle sits right next to its own “Menu”/“Bar” word, so nothing is ambiguous and the columns line up; thermal & uptime stay menu-only, so their bar switch is dimmed/disabled. Capsules follow the menu's row order, and hiding all of them drops the button to its static “P”
- The button's **NET capsule** shows pinned **arrow icons with right-aligned figures** (↓ over ↑, no bar), and the figures use the same B → KB → MB → GB ladder as the dashboard — one network unit everywhere, so a quiet 512 B/s connection reads identically in the menu, the button, and the dashboard
- The status menu opens **centered directly under the button** (clamped to the display) instead of the system's left-anchored placement, which slid wide menus so they appeared elsewhere; rows are a bit narrower to match

### Fixed
- **The toggle blink** (stat turned off → capsule vanished, reappeared, vanished again): the settings file now carries a revision number that both sides honor, so a stale poll can no longer re-apply an old layout for a cycle — and settings written by one side (app, web) can no longer be silently reverted when the other saves
- The dashboard Settings dialog scrolls on short windows instead of clipping, so the status-rows card is always reachable
- After a rebuild with "Start at login" on: the app restarted the background daemon onto the new code instead of spawning a *second* parallel sampler beside the stale daemon (that double sampling could make the menu and status bar look stuck or skewed)
- Dashboard: the thermal chip on the CPU card is now a warning — it appears only when the machine is actually slowed/throttled
- The NET capsule figures no longer shift as digit counts change — the arrows stay pinned and the figures align to a fixed edge

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
