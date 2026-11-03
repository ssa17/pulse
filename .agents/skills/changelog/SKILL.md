---
name: changelog
description: Maintain CHANGELOG.md in the Pulse repo — at commit time, add a bullet under [Unreleased] for anything user-visible in the change, and condense the pending entries into a concise "what's new" before a release. Use whenever committing changes in this repo, and when the user asks to release, bump the version, or prepare release notes.
---

# Changelog

This repo drives each release's Sparkle "what's new" from `CHANGELOG.md`.
Two jobs: keep the `[Unreleased]` bucket current, and summarize it before release.

## 1. Log user-visible changes (at commit time)

When changes are about to be committed, inspect what's actually in the diff
and ask: **will a Pulse user notice this?**

**Yes → add a bullet** under `## [Unreleased]` in `CHANGELOG.md`, included in
**the same commit** as the change. No → commit as normal.

Counts as user-visible:

- new features or capabilities
- UI / look changes (layout, colors, wording, new controls, corner styles)
- changed behavior a user can perceive (new defaults, settings, interactions)
- fixes for bugs a user would have experienced
- new keyboard shortcuts, menu items, dialogs, status-bar options

Does **not** count (skip):

- refactors, renames, or cleanup with identical behavior
- docs, tests, build/CI, packaging plumbing
- version bumps (the release step records those itself)
- perf/robustness work with no observable difference

Format rules:

- One line per bullet, present tense, from the user's perspective — no internals.
  - good: `Dashboard: memory bar now shows a separate cache segment`
  - bad: `normalized vm_stat segments in sample()`
- Keep the `### Added` / `### Changed` / `### Fixed` group headers in that order;
  create a group if missing, drop it if it ends up empty.
- If a similar bullet already exists, **refine it** instead of adding a duplicate.
- Include the changelog edit in the **same commit** as the change it describes.

## 2. Summarize before a release

When the user asks to release (or to run `fastlane release`), do this **first**:

1. Read the `## [Unreleased]` section of `CHANGELOG.md`.
2. Rewrite it as a concise "what's new":
   - merge related or duplicate bullets (many small fixes → one line,
     e.g. `Fixed several process-parsing edge cases`)
   - aim for 5–8 bullets total; never more than ~12
   - keep the `### Added` / `### Changed` / `### Fixed` grouping; drop empty groups
   - user-facing language only — commit phrasing and code names don't belong here
3. Save the summarized section back to `CHANGELOG.md` (leave it uncommitted —
   the release commit picks it up together with the appcast + the reset).
4. Show the user the summary, then run `fastlane release`.

The Fastfile step is mechanical — it consumes whatever is under `[Unreleased]`
into the appcast, embeds it in the Sparkle update dialog, and resets the bucket.
So **this summarizing step is what keeps the notes unconvoluted**: never let a
raw pile of bullets be the release notes.

If the user asks for release notes without a full release (e.g. for a GitHub
release body), produce the same summarized text without touching the Fastfile flow.
