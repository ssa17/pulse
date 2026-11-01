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
  parsed page size, never hardcode it.
- **Icons** are extracted with `sips` and cached in `~/.pulse/icons` keyed by
  md5(bundle path); the cache is never invalidated (a moved/renamed bundle simply
  gets a new key).
