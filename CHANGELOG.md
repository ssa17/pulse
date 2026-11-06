# Changelog

All notable changes to Pulse, newest first.

This file is the source of each release's **"what's new"**: at release time the
Fastfile turns the **Unreleased** section into the Sparkle release notes (shown
in the auto-update dialog), then resets the section to a fresh empty bucket.
Add a bullet under **Unreleased** whenever you ship something user-visible.

## [Unreleased]

### Added
- Memory: "Purge disk cache" button in the memory info popover — a Touch ID /
  password prompt (shown as Pulse), then it clears cached file data + apps'
  discardable buffers and reports exactly how much RAM came back
- Memory card: info button explaining what wired / compressed / file cache
  actually are, with live sparklines and how to free each of them
- Status bar: vertical bar mode — the menu-bar item shows capsule bars for CPU
  and memory, with the letters evenly sized and spaced
- Dashboard: right-click a row or process for quick Quit, Force Quit, Terminate, and Force Kill actions (also in the details sheet); quitting apps show a "closing…" tag while exiting, and stubborn processes escalate to Force Kill
- Search & navigation: press ⌘F or `/` to jump to search, and Esc to dismiss context menus, popovers, the details sheet, or active search step by step
- Process list: `kernel_task` now appears alongside other system processes

### Changed
- Dashboard: right-clicking no longer highlights app names or any other display text (the custom context menu still opens as before)
- Status bar: trimmed the dead space around the menu-bar icon so it sits right up next to your other menu-bar items like any of them
- Status bar: the sparkline view and its menu toggle are gone — the item always shows the vertical bars
- Memory card: redesigned header and 2×2 legend — removed duplicate file-cache and Free clutter, fixed header/info-button wrapping, made Wired / Compressed / Cache clickable to open the breakdown, and hid swap until 16 MB+ is in use
- Network card: headline now shows combined ↓ + ↑ throughput matching its sparkline, with download and upload split in the subtitle
- Quit app no longer asks for confirmation for regular apps (they get a polite
  SIGTERM and handle their own save prompts, like Cmd-Q does); system
  processes and Force Quit still confirm first
- Dashboard: battery readout no longer shows the time-remaining estimate (varies too much between machines to be useful)
- Header: the system info line is centered, with even spacing to the app name
  and the uptime
- Header: the load average readout is gone — it was rarely consulted and took
  space from the system info line
- Memory: figures now match Activity Monitor — each app shows the same number
  as AM's Memory column, the card reports AM's "Memory Used" and Cached Files
  (file-backed + purgeable), and the bar's cache segment shows the real cache

### Fixed
- Header: battery no longer shows the ⚡ charging bolt while discharging or plugged in on hold ("not charging")
- App list: apps and processes without a bundle icon now show an initial, system gear, or CLI badge instead of `?`
- Status-bar item: fixed layout issues on macOS 26/27
- Processes whose `ps` output has leading whitespace now parse correctly
- Dashboard and backend stay in sync across updates and rebuilds — no more new UI talking to a stale backend process
- Memory bar: compressed (and, on machines with a large wired pool, cache)
  could be reported as 0 even while macOS was actively compressing — the bar
  now shows the real compressed pool, and the info popover no longer claims
  "nothing is compressed"
- CPU card: no longer blips to the all-time boot average for a moment after a
  kill, purge, or window re-focus — it keeps the last real 1-second reading

## [1.1] - 2026-11-02

### Changed
- Runs on macOS 13+ (deployment target pinned — previously the app only ran
  on the macOS version it was built with)

## [1.0] - 2026-11-01

### Added
- Initial public release: live CPU / memory / network / disk dashboard,
  per-app drill-down with process list, kill / quit, menu-bar status item,
  Sparkle auto-updates
