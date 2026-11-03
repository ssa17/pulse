# Changelog

All notable changes to Pulse, newest first.

This file is the source of each release's **"what's new"**: at release time the
Fastfile turns the **Unreleased** section into the Sparkle release notes (shown
in the auto-update dialog), then resets the section to a fresh empty bucket.
Add a bullet under **Unreleased** whenever you ship something user-visible.

## [Unreleased]

### Added
- Status bar: vertical bar mode alongside the sparklines (toggle from the
  item's menu; the choice persists)
- Dashboard: right-click a row or a process for a quick menu with "Quit app"
  — no need to open the details sheet first; a quitting app shows a
  "closing…" tag and fades while it exits

### Changed
- Quit app no longer asks for confirmation for regular apps (they get a polite
  SIGTERM and handle their own save prompts, like Cmd-Q does); system
  processes still confirm first
- Dashboard: battery readout no longer shows the time-remaining estimate (varies too much between machines to be useful)

### Fixed
- Status-bar item: fixed layout issues on macOS 26/27
- Processes whose `ps` output has leading whitespace now parse correctly
- Dashboard no longer shows a stale interface after an update

## [1.1] - 2026-11-02

### Changed
- Runs on macOS 13+ (deployment target pinned — previously the app only ran
  on the macOS version it was built with)

## [1.0] - 2026-11-01

### Added
- Initial public release: live CPU / memory / network / disk dashboard,
  per-app drill-down with process list, kill / quit, menu-bar status item,
  Sparkle auto-updates
