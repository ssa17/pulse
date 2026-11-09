# Gotchas — non-obvious things in the sampling/parsing layer

These are why the parsers in `server.js` are shaped the way they are. Read this when
touching sampling, parsing, or app attribution. Each item is a real output-format
quirk of a macOS tool, verified against live output.

- **ps parsing**: `comm`/`args` are the last column because they contain spaces.
  CPU% comes from the *delta of cumulative CPU time* (`ps time`), not from `ps`'s
  own pcpu (a lifetime average); new processes fall back to pcpu.
- **iostat** `-c 2` prints two blocks: the first is a cumulative average since boot
  (useless for a live rate) — the parser sums only the most recent block.
- **netstat -ib** columns: `Name Mtu Network Address Ipkts Ierrs Ibytes Opkts Oerrs Obytes Coll`.
  A full row has 11 fields, but a link row with an EMPTY Address loses a field
  on whitespace split → 10 fields, shifting Ibytes/Obytes one column left
  (hence `a = isLink ? 5 : 6`). Each interface also prints one row per address
  with identical (repeated) counters — dedupe by name, preferring the link row,
  or traffic double-counts. Per-address rows may print `-` where counters are
  not applicable (`+x || 0` absorbs it). Counters are BYTES: `netRate` is
  bytes/s with TWO consumers — the snapshot's `sys.net` and `/api/status` both
  ship bytes/s; the dashboard formats via `fmtBytes` and the app via its own
  1024-based ladder, so neither converts in band (a conversion is how the
  GB-figure bug happened).
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
- **GPU utilization comes from `ioreg -r -l -c AGXDeviceUserClient`** (Apple
  Silicon only, root-free — `powermetrics` needs superuser and the `gpu_util`
  sampler is gone on current macOS). Each GPU client node carries `AppUsage` with
  `accumulatedGPUTime` (cumulative nanoseconds); utilization = delta over the real
  interval ÷ number of MGPU units (from the accelerator node's
  `GPUConfigurationVariable`, e.g. 4 on an M4 Max). Quirks: the plist prints
  `AppUsage` BEFORE `IOUserClientCreator` (alphabetical), so the parser works per
  node block, never with a flat scan; a process may hold several contexts (sum
  them); the class name is AGX-specific, so machines without one simply report
  `gpu.pct: null` and the card shows "—". The accelerator node (discovered by
  class-name scan of `ioreg -p IOService`) also supplies `"model"` and
  `"gpu-core-count"` for the card's caption.
- **Thermal readings & state**: CPU temperature comes from Apple Silicon on-die
  thermal sensors via the IOKit HID Event System (`app/pulse-thermal.c`, root-free),
  sampling `PMU tdie` sensors. It runs in the background and is non-blocking.
  Throttling warning levels come from `pmset -g batt -g therm`: "No … has
  been recorded" means level 0 (nominal); an active throttle prints
  "… thermal level N" (0 = nominal, 1 = slowed, ≥2 = throttled).
  The dashboard CPU card always shows the live CPU die temperature; the
  menu-bar has a Thermal row pinned directly below CPU (no settings toggle,
  no bar). Both colour the rounded reading on the machine's observed low–high
  range (server ships `thermal.min`/`thermal.max`) with the span floored at
  10°C — a quiet machine's few-degree range must not paint a 1° swing across
  the whole green→red ramp, and the rounded value keeps the two UIs in lockstep.
  Uptime is `kern.boottime` (already in the sysctl batch).
