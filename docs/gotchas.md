# Gotchas — non-obvious things in the sampling/parsing layer

These are why the parsers in `server.js` are shaped the way they are. Read this when
touching sampling, parsing, or app attribution. Each item is a real output-format
quirk of a macOS tool, verified against live output.

- **ps parsing**: `comm`/`args` are the last column because they contain spaces.
  CPU% comes from the *delta of cumulative CPU time* (`ps time`), not from `ps`'s
  own pcpu (a lifetime average); new processes fall back to pcpu.
- **iostat** `-c 2` prints two blocks: the first is a cumulative average since boot
  (useless for a live rate) — the parser sums only the most recent block.
- **netstat -ib** prints each interface once per address with identical counters;
  the parser dedupes by name, preferring the 10-column link row (the Address
  column is absent there, which shifts the column indices).
- **App attribution**: the *outermost* .app bundle in the exe path wins (nested
  helper bundles resolve to the real app); otherwise walk up to 8 parent levels
  (so a `node` spawned by VS Code shows up under VS Code).
- **vm_stat** page size varies (16384 on Apple Silicon) — always multiply by the
  parsed page size, never hardcode it. Activity Monitor's "Cached Files" is
  `File-backed pages + Pages purgeable`; we cap that sum to `used − wired −
  compressed` to guard against transient non-atomic `vm_stat` counter skew so
  the four bar segments always sum cleanly to `used`.
- **Per-process wired/compressed is not available** to a regular user binary:
  `task_for_pid` only succeeds for the calling process itself (task ports are
  gated behind Apple's private `get-task-ports` entitlement — ad-hoc signing
  doesn't help), so `task_info(TASK_VM_INFO)` is unreachable for other
  processes, and `proc_pidinfo`'s `pri_user_wired_count` is dead on current
  macOS (system-wide total is ~0 while vm_stat reports tens of GB wired).
  Don't try to rebuild a per-app wired/compressed split — the UI's memory info
  popover therefore explains the vm_stat aggregates instead. (Verified on
  macOS 27, 2026.)
- **Per-process memory (phys_footprint) and PID 0 (`kernel_task`) come from `top`**,
  the one per-process source a regular binary can get: `top` is Apple-platform-signed
  and holds the entitlements to read every process's task info, so its `mem` column is
  the kernel's phys_footprint — the same number Activity Monitor displays (RSS
  minus shared file pages, i.e. no dyld-shared-cache double-count) — and it also
  surfaces `PID 0` (`kernel_task`), which `ps -axo` omits. Pass `-F` to skip
  shared-library region scanning (faster and lighter). Quirks:
  `-l 2` repeats the whole header per sample (the last occurrence of a pid
  wins), values are human-scaled (`1456K`/`646M`/`22G`, never decimal) with a
  trailing `+`/`-`/space delta marker to strip, and `-n N` keeps only the top N
  by the `-o` sort key — sort by mem, fall back to ps RSS for unlisted pids.
  The sub-MB tail is the only data lost. (Verified on macOS 27, 2026.)
  One trap: a single-shot sample (`-l 1`, the fast path) makes the `CPU
  usage:` line the average-SINCE-BOOT, not the current load — rates must
  come from the 2nd sample of `-l 2`, so the fast path updates per-process
  mem but never the system CPU (and kernel_task's cpu), which stay at the
  last real window instead.
- **proc_listallpids** returns a pid COUNT, not a byte count (the man page is
  stale), and **proc_pidinfo** returns 0 (no partial fill) when the buffer is
  smaller than the struct — size buffers ≥ 256B. `purge` needs root; a
  non-root run is a no-op ("Operation not permitted").
- **Icons** are extracted with `sips` and cached in `~/.pulse/icons` keyed by
  md5(bundle path); the cache is never invalidated (a moved/renamed bundle simply
  gets a new key).
