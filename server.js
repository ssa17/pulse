#!/usr/bin/env node
/**
 * Pulse — real-time macOS resource dashboard.
 *
 * Zero-dependency Node.js backend:
 *  - samples the whole system every second (ps, vm_stat, sysctl, top, netstat, iostat, pmset, ioreg)
 *  - groups every process into the app it belongs to (bundle detection + parent-chain walk)
 *  - streams a full snapshot to the browser over Server-Sent Events
 *
 * Run:  node server.js   →  http://127.0.0.1:8787
 *
 * The snapshot built in sample() is the contract with public/index.html, and
 * /api/status is the contract with app/Pulse.swift — see docs/contracts.md for the
 * full schemas and AGENTS.md for the cross-component invariants.
 */
'use strict';

const http = require('http');
const fs = require('fs');
const path = require('path');
const os = require('os');
const crypto = require('crypto');
const { execFile, execFileSync, spawn } = require('child_process');

const HOST = process.env.HOST || '127.0.0.1';
// App mode (PULSE=1) binds a dynamic port (0 → OS picks a free one) unless PORT
// is set explicitly; plain web mode keeps a friendly fixed default.
const PORT = process.env.PORT !== undefined ? +process.env.PORT : (process.env.PULSE === '1' ? 0 : 8787);
const INTERVAL = +(process.env.INTERVAL || 1000);
// App version for the UI. The single source of truth is app/Info.plist
// (CFBundleShortVersionString) — macOS, Sparkle, and the About panel read it
// too. App mode: the app passes it as PULSE_VERSION. Web mode: read the plist
// (package.json is kept in sync by app/build.sh, but is not read here).
function plistVersion(file) {
  try {
    return execFileSync('plutil', ['-extract', 'CFBundleShortVersionString', 'raw', file],
                        { encoding: 'utf8' }).trim() || null;
  } catch { return null; }
}
const VERSION = process.env.PULSE_VERSION
  || plistVersion(path.join(__dirname, 'app', 'Info.plist'))   // web mode (repo root)
  || plistVersion(path.join(__dirname, '..', 'Info.plist'));   // app mode (Contents/Resources)
const SERVER_MTIME = (() => {
  try { return Math.floor(fs.statSync(__filename).mtimeMs / 1000); } catch { return 0; }
})();
// Shared state lives in ~/.pulse (port file + icon cache) — never inside the app
// bundle, which should stay immutable.
const PULSE_DIR = path.join(os.homedir(), '.pulse');
const PORT_FILE = process.env.PULSE_PORT_FILE || path.join(PULSE_DIR, 'port');
const ICON_DIR = path.join(PULSE_DIR, 'icons');
const _PUBLIC_DIR = path.join(__dirname, 'public');

// When running from the app bundle, check if a source public/ exists in the
// project tree (dist/Pulse.app/Contents/Resources/public → look upwards for
// a Pulse checkout: a public/ whose parent also holds server.js).  That lets
// UI edits show up on restart without a rebuild.  A released app (e.g. in
// /Applications) never matches and keeps using the bundled copy.
const PUBLIC_DIR = (() => {
  let dir = path.dirname(_PUBLIC_DIR);
  for (let i = 0; i < 5; i++) {
    dir = path.dirname(dir);
    const candidate = path.join(dir, 'public');
    if (fs.existsSync(candidate) && fs.existsSync(path.join(dir, 'server.js'))) return candidate;
  }
  return _PUBLIC_DIR;
})();

fs.mkdirSync(ICON_DIR, { recursive: true });

let uiMtime = 0;
function refreshUiMtime() {
  fs.stat(path.join(PUBLIC_DIR, 'index.html'), (err, st) => {
    if (!err && st) uiMtime = Math.floor(st.mtimeMs / 1000);
  });
}
refreshUiMtime();

// Startup trace timestamps (stage names + epoch ms only — never process names/args).
const BOOT_TRACE = { start: Date.now(), listen: 0, firstSnapshot: 0 };

// Show up nicely in Activity Monitor / ps when running as the app's backend.
process.title = 'Pulse';

// Safety net: when launched by the Pulse app, exit if our parent (the app) dies,
// so a crashed/killed app never leaves an orphaned backend behind.
// Launchd-managed background daemons (ppid === 1 or PULSE_DAEMON === '1') skip this.
// (process.ppid is cached at startup; signal 0 is the live existence check.)
if (process.env.PULSE === '1' && process.env.PULSE_DAEMON !== '1') {
  const parentPid = process.ppid;
  if (parentPid !== 1) {
    setInterval(() => {
      try {
        process.kill(parentPid, 0);
      } catch {
        process.exit(0); // parent is gone → don't linger as an orphan
      }
    }, 2000);
  }
}

/* ------------------------------------------------------------------ *
 *  Command runner
 * ------------------------------------------------------------------ */
/**
 * Run a command, resolve with stdout or null. Never rejects: a failed or
 * timed-out command resolves null, but partial output is kept even when the
 * command exits non-zero (some of these tools print data before erroring).
 */
function run(cmd, args, timeout = 8000) {
  return new Promise((resolve) => {
    try {
      execFile(cmd, args, { timeout, maxBuffer: 64 * 1024 * 1024 },
        (err, stdout) => resolve(err && !stdout ? null : stdout));
    } catch {
      resolve(null);
    }
  });
}

/* ------------------------------------------------------------------ *
 *  Parsers
 * ------------------------------------------------------------------ */

/** "9:30.30" | "0:00.04" | "1:02:03.5"  →  seconds */
function parseCpuTime(s) {
  if (!s) return 0;
  let sec = 0;
  for (const part of s.split(':')) sec = sec * 60 + (parseFloat(part) || 0);
  return sec;
}

/** ps -axo pid=,ppid=,user=,time=,pcpu=,rss=,vsz=,stat=,etime=,comm=  (comm last: may contain spaces) */
function parsePsMain(out) {
  const map = new Map();
  if (!out) return map;
  const re = /^\s*(\d+)\s+(\d+)\s+(\S+)\s+(\S+)\s+([\d.]+)\s+(\d+)\s+(\d+)\s+(\S+)\s+(\S+)\s(.*)$/;
  for (const line of out.split('\n')) {
    const m = line.match(re);
    if (!m) continue;
    const [, pid, ppid, user, time, pcpu, rss, vsz, stat, etime, comm] = m;
    map.set(+pid, {
      pid: +pid, ppid: +ppid, user,
      cpuTime: parseCpuTime(time),
      pcpu: +pcpu,
      rss: +rss, vsz: +vsz, stat, etime,
      exe: comm.trim(),
    });
  }
  return map;
}

/** ps -axo pid=,args=  (args last: may contain spaces) */
function parsePsArgs(out) {
  const map = new Map();
  if (!out) return map;
  for (const line of out.split('\n')) {
    const m = line.match(/^(\d+)\s(.*)$/);
    if (!m) continue;
    map.set(+m[1], m[2].trim());
  }
  return map;
}

function parseVmStat(out) {
  const r = {
    free: 0, active: 0, inactive: 0, speculative: 0, wired: 0, purgeable: 0,
    filebacked: 0, anonymous: 0, storedCompressed: 0, compressed: 0,
  };
  if (!out) return r;
  const page = +(out.match(/page size of (\d+)/) || [])[1] || 16384;
  const grab = (re) => { const m = out.match(re); return m ? +m[1] * page : 0; };
  r.free = grab(/Pages free:\s*(\d+)/);
  r.active = grab(/Pages active:\s*(\d+)/);
  r.inactive = grab(/Pages inactive:\s*(\d+)/);
  r.speculative = grab(/Pages speculative:\s*(\d+)/);
  r.wired = grab(/Pages wired down:\s*(\d+)/);
  r.purgeable = grab(/Pages purgeable:\s*(\d+)/);
  r.filebacked = grab(/File-backed pages:\s*(\d+)/);
  r.anonymous = grab(/Anonymous pages:\s*(\d+)/);
  // "stored" = the ORIGINAL (uncompressed) size of the pages the compressor is
  // holding; "occupied" = what they actually take in RAM after compression.
  r.storedCompressed = grab(/Pages stored in compressor:\s*(\d+)/);
  // "Pages occupied by compressor" is the standard line; the "Compressed"
  // pattern is a fallback for alternate vm_stat output formats.
  r.compressed = grab(/Pages occupied by compressor:\s*(\d+)/) || grab(/"Compressed"\s*:\s*(\d+)/);
  return r;
}

function parseSize(v, unit) {
  const n = +v;
  const mult = { B: 1, K: 1024, M: 1024 ** 2, G: 1024 ** 3, T: 1024 ** 4 }[(unit || 'B').toUpperCase()] || 1;
  return n * mult;
}

function parseSysctl(out) {
  const r = { memTotal: 0, cores: os.cpus().length, swapTotal: 0, swapUsed: 0, bootTime: 0 };
  if (!out) return r;
  const g = (re) => { const m = out.match(re); return m ? m[1] : null; };
  r.memTotal = +(g(/hw\.memsize:\s*(\d+)/)) || 0;
  r.cores = +(g(/hw\.ncpu:\s*(\d+)/)) || r.cores;
  const sw = out.match(/vm\.swapusage:.*?total = ([\d.]+)([KMGT]?)[B]?.*?used = ([\d.]+)([KMGT]?)[B]?/);
  if (sw) { r.swapTotal = parseSize(sw[1], sw[2]); r.swapUsed = parseSize(sw[3], sw[4]); }
  const bt = out.match(/kern\.boottime:\s*\{\s*sec = (\d+)/);
  if (bt) r.bootTime = +bt[1];
  return r;
}

/** top -l 2 -n 0 -s 1 → use the LAST sample (real usage over the 1s window) */
function parseTop(out) {
  const r = { user: 0, sys: 0, idle: 0, total: 0 };
  if (!out) return r;
  const lines = out.match(/CPU usage:.*$/gm) || [];
  const last = lines[lines.length - 1];
  if (!last) return r;
  const u = last.match(/([\d.]+)% user/);
  const s = last.match(/([\d.]+)% sys/);
  const i = last.match(/([\d.]+)% idle/);
  r.user = u ? +u[1] : 0;
  r.sys = s ? +s[1] : 0;
  r.idle = i ? +i[1] : 0;
  r.total = +Math.max(0, Math.min(100, 100 - r.idle)).toFixed(2);
  return r;
}

/**
 * Compute system-wide CPU percentages { user, sys, idle, total } from two
 * `os.cpus()` snapshots (`host_processor_info` tick counters). Used when the
 * dashboard has no active viewers so background menu-bar sampling doesn't need
 * to spawn `/usr/bin/top` (which walks every process's Mach VM map).
 */
function computeHostCpuDelta(prevCpus, curCpus) {
  if (!Array.isArray(prevCpus) || !Array.isArray(curCpus) || !prevCpus.length || prevCpus.length !== curCpus.length) {
    return null;
  }
  let dUser = 0, dSys = 0, dIdle = 0;
  for (let i = 0; i < curCpus.length; i++) {
    const p = prevCpus[i] && prevCpus[i].times;
    const c = curCpus[i] && curCpus[i].times;
    if (!p || !c) return null;
    dUser += Math.max(0, (c.user - p.user) + (c.nice - p.nice));
    dSys += Math.max(0, (c.sys - p.sys) + (c.irq - p.irq));
    dIdle += Math.max(0, c.idle - p.idle);
  }
  const sum = dUser + dSys + dIdle;
  if (sum <= 0) return null;
  const user = +((dUser / sum) * 100).toFixed(2);
  const sys = +((dSys / sum) * 100).toFixed(2);
  const idle = +((dIdle / sum) * 100).toFixed(2);
  const total = +Math.max(0, Math.min(100, 100 - idle)).toFixed(2);
  return { user, sys, idle, total };
}

/**
 * Compute real-time load % for Apple Silicon Efficiency (E) and Performance (P) core clusters.
 * On Apple Silicon, E-cores always precede P-cores in `os.cpus()`.
 */
function computeCoreClusterLoads(prevCpus, curCpus, eCount) {
  if (!Array.isArray(prevCpus) || !Array.isArray(curCpus) || prevCpus.length !== curCpus.length || eCount <= 0) {
    return { eCores: null, pCores: null };
  }
  function calcRange(start, end) {
    let busy = 0, total = 0;
    for (let i = start; i < end && i < curCpus.length; i++) {
      const p = prevCpus[i] && prevCpus[i].times;
      const c = curCpus[i] && curCpus[i].times;
      if (!p || !c) continue;
      const b = (c.user - p.user) + (c.nice - p.nice) + (c.sys - p.sys) + (c.irq - p.irq);
      const idle = c.idle - p.idle;
      busy += Math.max(0, b);
      total += Math.max(0, b) + Math.max(0, idle);
    }
    return total > 0 ? +((busy / total) * 100).toFixed(1) : 0;
  }
  const eCores = calcRange(0, eCount);
  const pCores = calcRange(eCount, curCpus.length);
  return { eCores, pCores };
}

/**
 * top -F -l 2 -n 800 -o mem -stats pid,cpu,mem → pid → { mem, cpu }.
 * The MEM column is the kernel's phys_footprint — the same number Activity
 * Monitor shows: RSS with shared file pages (dyld shared cache, app bundles)
 * excluded, so apps stop double-counting each other. `top` is an Apple
 * platform binary holding the entitlements to read task info of every process
 * (a regular binary cannot — see docs/gotchas.md), so it is the only way to
 * get per-process footprint — and PID 0 (`kernel_task`, omitted by `ps`) —
 * without root.
 * Format quirks: top prints the whole header (incl. the PID/MEM column line)
 * once per sample, so the last occurrence of a pid wins; values are
 * human-scaled (1456K / 646M / 22G, never decimal) with a trailing +/-/space
 * delta marker that is stripped; -o mem sorts by memory so -n 800 keeps the
 * ones that matter — anything unlisted (sub-MB tail) falls back to RSS.
 */
function parseTopProcs(out) {
  const map = new Map();
  if (!out) return map;
  for (const line of out.split('\n')) {
    const m = line.match(/^\s*(\d+)\s+(?:([\d.]+)\s+)?(\d+)([KMGTP]?B?)\s*[+-]?\s*$/);
    if (!m) continue;
    const mult = { K: 1024, M: 1024 ** 2, G: 1024 ** 3, T: 1024 ** 4, P: 1024 ** 5 }[(m[4] || '')[0]] || 1;
    map.set(+m[1], {
      mem: +m[3] * mult,
      cpu: m[2] !== undefined ? +m[2] : null,
    });
  }
  return map;
}

function parseTopMem(out) {
  const map = new Map();
  for (const [pid, v] of parseTopProcs(out)) map.set(pid, v.mem);
  return map;
}

/**
 * netstat -ib → per-interface byte counters.
 * Each interface appears once per address (identical counters); the link row
 * (<Link#N>) may or may not have an Address column, so we dedupe by interface
 * name and prefer the 10-column link row. Loopback is excluded.
 */
function parseNetstat(out) {
  let ib = 0, ob = 0;
  if (!out) return { ib, ob };
  const byName = new Map(); // name → { ib, ob, isLink }
  for (const line of out.split('\n').slice(1)) {
    const c = line.trim().split(/\s+/);
    if (c.length < 10) continue;
    const name = c[0];
    if (name.startsWith('lo')) continue; // loopback is not real network traffic
    const isLink = c.length === 10;
    const a = isLink ? 5 : 6; // Ibytes column
    const b = isLink ? 8 : 9; // Obytes column
    const cur = byName.get(name);
    if (!cur || isLink) byName.set(name, { ib: +c[a] || 0, ob: +c[b] || 0 });
  }
  for (const v of byName.values()) { ib += v.ib; ob += v.ob; }
  return { ib, ob };
}

/**
 * iostat -d -c 2 -w 1 → sum MB/s of the most recent sample block.
 * -c 2 prints TWO blocks of per-disk rows (KB/t, tps, MB/s): the first is a
 * cumulative average since boot (useless for a live rate), the second is the
 * real 1s window. Each block has one row per disk, so "the last half of the
 * numeric rows" is the recent block; c[2] is the MB/s column.
 */
function parseIostat(out) {
  if (!out) return 0;
  const rows = [];
  for (const line of out.split('\n')) {
    const c = line.trim().split(/\s+/);
    if (c.length === 3 && c.every((x) => /^[\d.]+$/.test(x))) rows.push(+c[2]);
  }
  if (!rows.length) return 0;
  const half = Math.ceil(rows.length / 2);
  return rows.slice(rows.length - half).reduce((a, b) => a + b, 0);
}

/** pmset -g batt → e.g. " -InternalBattery-0 (id=…) 86%; charging; 2:31 remaining"
 *  or "80%; AC attached; not charging present: true". Only true active charging
 *  ("charging" / "finishing charge") sets `charging` — not "discharging" or "not charging".
 */
function parseBatt(out) {
  const r = { pct: null, charging: false };
  if (!out) return r;
  const m = out.match(/(\d+)\s*%;\s*([^;\n]+)/);
  if (m) {
    r.pct = +m[1];
    const state = m[2].replace(/\s+present:.*$/i, '').trim();
    r.charging = /^(charging|finishing charge)$/i.test(state);
  }
  return r;
}

/**
 * `pmset -g batt -g therm` → thermal state, combined with IOHIDEventSystem CPU temperature.
 * pmset is the root-free source of the SMC thermal warning level: "No … has been recorded"
 * means level 0 (Nominal); an active throttle prints "… thermal level N" (1 = slowed,
 * ≥2 = throttled). When available, `cpuTemp` provides the live CPU die temperature (°C).
 */
function parseTherm(out, cpuTemp = null) {
  let level = 0;
  if (out) {
    for (const m of out.matchAll(/(?:thermal|performance) level (\d+)/g)) level = Math.max(level, +m[1]);
  }
  const state = level === 0 ? 'nominal' : level === 1 ? 'slowed' : 'throttled';
  return { level, state, cpu: typeof cpuTemp === 'number' ? +cpuTemp.toFixed(1) : null };
}

function parseThermalJson(out) {
  if (!out) return null;
  try {
    const data = JSON.parse(out);
    return typeof data.cpu === 'number' ? data : null;
  } catch {
    return null;
  }
}

/**
 * `ioreg -r -l -c AGXDeviceUserClient` → pid → { name, ns }.
 * Each Apple Silicon GPU client exposes AppUsage with `accumulatedGPUTime`
 * (cumulative nanoseconds) — the only root-free GPU utilization source (see
 * docs/gotchas.md). Parsed per node block: the plist prints `AppUsage`
 * BEFORE `IOUserClientCreator` (alphabetical), so a flat scan would attribute
 * a node's usage to the previous node's pid.
 */
function parseIoregGpu(out) {
  const map = new Map();
  if (!out) return map;
  for (const block of out.split(/<class AGXDeviceUserClient[^\n]*/g)) {
    const c = block.match(/"IOUserClientCreator" = "pid (\d+), (\S+)"/);
    if (!c) continue;
    let ns = 0;
    for (const u of block.matchAll(/"accumulatedGPUTime"=(\d+)/g)) ns += +u[1];
    const e = map.get(c[1]);
    if (e) e.ns += ns;
    else map.set(c[1], { name: c[2], ns });
  }
  return map;
}

/**
 * Parse GPU memory currently in use (bytes) from IOKit IOAccelerator.
 * Matches `"In use system memory" = <bytes>`.
 */
function parseGpuMem(out) {
  if (!out) return null;
  const m = out.match(/"In use system memory"\s*=\s*(\d+)/);
  return m ? parseInt(m[1], 10) : null;
}

// Status-menu row ids. settings.json stores an ordered SUBSET under `menuRows`
// (missing id = hidden row); the /api/status payload carries it so the app can
// rebuild its stat block. Thermal is not a row here — the app pins it directly
// below CPU (shared visibility, no toggle of its own).
const MENU_ROW_IDS = ['cpu', 'gpu', 'memory', 'network', 'uptime'];
// Network is on by default — it has a real value (MB/s) and a 1 Gbps reference scale.
const DEFAULT_MENU_ROWS = ['cpu', 'gpu', 'memory', 'network', 'uptime'];
function normalizeMenuRows(v) {
  if (Array.isArray(v)) {
    const out = [];
    for (const id of v) if (MENU_ROW_IDS.includes(id) && !out.includes(id)) out.push(id);
    return out; // may be empty — "all hidden" is a valid layout
  }
  return [...DEFAULT_MENU_ROWS];
}
// Status-BAR button ids — only the continuously-valued stats have capsules
// (uptime is a counter; thermal is pinned below CPU and has no capsule).
const BAR_ROW_IDS = ['cpu', 'gpu', 'memory', 'network'];
function normalizeBarRows(v, menuRows) {
  if (Array.isArray(v)) {
    const out = [];
    for (const id of v) if (BAR_ROW_IDS.includes(id) && !out.includes(id)) out.push(id);
    return out; // may be empty — the button falls back to a static “P”
  }
  // Key absent → follow the menu's visible set (capsules in the menu's order).
  return menuRows.filter((id) => BAR_ROW_IDS.includes(id));
}
let lastMenuRows = [...DEFAULT_MENU_ROWS];
let lastBarRows = [...BAR_ROW_IDS];
// Settings-file revision. Bumped on every layout write (app or web); the app
// uses it to ignore /api/status layouts that were read from disk BEFORE its own
// latest write — otherwise a stale poll re-applies the old capsule set for one
// cycle and the toggled stat blinks back on (off → on → off).
let lastLayoutGen = 0;

async function getHardware() {
  const hw = { model: os.hostname(), chip: null, memLabel: null };
  const out = await run('system_profiler', ['SPHardwareDataType'], 20000);
  if (out) {
    const g = (re) => { const m = out.match(re); return m ? m[1].trim() : null; };
    hw.model = g(/Model Name:\s*(.+)/) || hw.model;
    hw.chip = g(/Chip:\s*(.+)/) || g(/Processor Name:\s*(.+)/);
    hw.memLabel = g(/Memory:\s*(.+)/);
  }
  return hw;
}

/* ------------------------------------------------------------------ *
 *  App intelligence: process → app
 * ------------------------------------------------------------------ */

/**
 * Find the OUTERMOST .app bundle an executable path lives in (if any).
 * Helper executables can be nested in their own .app inside the real app
 * (e.g. .../Google Chrome.app/.../Helpers/Chrome Helper (Aperitif).app/...),
 * so we take the FIRST .app in the path.
 */
function bundleOf(exePath) {
  if (!exePath) return null;
  const m = exePath.match(/^(.*?\.app)(\/|$)/);
  if (m && m[1].length > 1) {
    return { bundle: m[1], name: path.basename(m[1], '.app') };
  }
  return null;
}

function isSystemPath(p) {
  return (
    p.startsWith('/System/') || p.startsWith('/bin/') || p.startsWith('/sbin/') ||
    p.startsWith('/cores/') || p.startsWith('/usr/libexec') || p.startsWith('/usr/bin') ||
    p.startsWith('/usr/sbin') || p.startsWith('/usr/lib') || p.startsWith('/usr/share') ||
    p.startsWith('/private/var/') || p.startsWith('/Library/Apple/')
  );
}

/**
 * Attribute a process to a group:
 *  1. its own executable is inside a .app bundle  → that app
 *  2. an ancestor (up to 8 levels) is inside a .app → that app (spawned children)
 *  3. inside a .appex (system extension)          → the extension
 *  4. otherwise                                   → grouped by executable name
 */
function groupOf(p, procs) {
  let cur = p;
  for (let depth = 0; cur && depth <= 8; depth++) {
    const b = bundleOf(cur.exe);
    if (b) return { key: 'app:' + b.bundle, name: b.name, kind: 'app', bundle: b.bundle };
    if (!cur.ppid || cur.ppid === cur.pid) break;
    cur = procs.get(cur.ppid);
  }
  const exe = p.exe;
  const a = exe.lastIndexOf('.appex/');
  if (a > 0) {
    const b = exe.slice(0, a + 7);
    return { key: 'appex:' + b, name: path.basename(b, '.appex'), kind: 'system', bundle: null };
  }
  const name = path.basename(exe) || 'unknown';
  return { key: 'exe:' + name, name, kind: isSystemPath(exe) ? 'system' : 'other', bundle: null };
}

/** One-line explanations for well-known macOS processes. */
const KNOWN = {
  kernel_task: 'Kernel — core system, GPU & power management',
  WindowServer: 'Display server — composites everything you see on screen',
  launchd: 'Init — starts and supervises every other process',
  mds: 'Spotlight — search database daemon',
  mds_stores: 'Spotlight — search database storage',
  mdworker: 'Spotlight — indexing files',
  mdworker_shared: 'Spotlight — shared indexing worker',
  logd: 'Unified logging system',
  syspolicyd: 'Gatekeeper — authorizes apps',
  trustd: 'Evaluates TLS certificate trust',
  apsd: 'Apple push notification service',
  biometd: 'Face ID / Touch ID',
  universalaccessd: 'Accessibility services',
  notificationcenterui: 'Notification Center UI',
  ControlCenter: 'Control Center UI',
  Dock: 'The Dock',
  Finder: 'File manager',
  Safari: 'Web browser',
  'Google Chrome': 'Web browser',
  node: 'Node.js runtime',
  python3: 'Python interpreter',
  zsh: 'Z shell',
  bash: 'Bourne shell',
  systemstats: 'System statistics daemon',
  reportcrash: 'Crash reporter',
  coreservicesd: 'Core Services daemon',
  cfprefsd: 'Preferences daemon',
  useractivityd: 'User activity tracking',
  talagent: 'App task scheduling',
  runningboardd: 'App lifecycle management',
  backboardd: 'App launch / termination',
  'com.apple.WebKit.WebContent': 'WebKit — web page rendering process',
  'com.apple.WebKit.GPU': 'WebKit — GPU & media process',
  'com.apple.WebKit.Networking': 'WebKit — networking process',
  'Safari Web Content': 'Safari — web page process',
  'Safari Web Content (Privileged)': 'Safari — privileged web process',
  'Safari Helper': 'Safari — helper process',
  'Google Chrome Helper (Renderer)': 'Chrome — a web page (tab)',
  'Google Chrome Helper (GPU)': 'Chrome — GPU rendering',
  'Google Chrome Helper (Utility)': 'Chrome — utility (audio, video, etc.)',
  'Google Chrome Helper': 'Chrome — helper process',
  WallpaperAgent: 'Wallpaper management',
  WallpaperAerialsExtension: 'Aerial (live) wallpaper',
  centaurid: 'Apple Intelligence — on-device models',
  modelcatalogd: 'Apple Intelligence — model catalog',
  IntelligenceController: 'Apple Intelligence controller',
  knowledgecd: 'Apple Intelligence — knowledge',
  amsaccountsd: 'Apple Media Services accounts',
  mediastreamd: 'Media streaming',
  rapportd: 'Handoff / Continuity',
  sharingd: 'Screen sharing / AirPlay',
  cloudd: 'iCloud sync',
  nsurlsessiond: 'URL session daemon',
  storeuid: 'App Store UI',
  appstoreagent: 'App Store agent',
  softwareupdated: 'Software Update daemon',
  diskarbitrationd: 'Disk arbitration',
  apfsd: 'APFS file system daemon',
  powerd: 'Power management',
  thermalmonitord: 'Thermal monitoring',
  opendirectoryd: 'Directory services (users)',
  configd: 'System configuration',
  distnoted: 'Distributed notifications',
  sysmond: 'System monitoring daemon',
  'Activity Monitor': 'Activity Monitor',
};

/** Guess the role of a helper process from its name. */
function roleOf(name) {
  const n = (name || '').toLowerCase();
  if (n.includes('renderer') || n.includes('web content')) return 'web page';
  if (n.includes('gpu')) return 'GPU';
  if (n.includes('shader')) return 'shader compiler';
  if (n.includes('utility')) return 'utility';
  if (n.includes('networking')) return 'networking';
  if (n.includes('audio')) return 'audio';
  if (n.includes('crashpad')) return 'crash handler';
  if (n.includes('helper')) return 'helper';
  return null;
}

/* ------------------------------------------------------------------ *
 *  Icons: extract .icns from app bundles → 64px PNG, cached
 * ------------------------------------------------------------------ */
const iconMap = new Map(); // bundle → { url?, ready }

function ensureIcon(grp) {
  if (!grp.bundle || iconMap.has(grp.bundle)) return;
  const entry = { ready: false };
  iconMap.set(grp.bundle, entry);
  const resDir = path.join(grp.bundle, 'Contents', 'Resources');
  let icns = null;
  try {
    const files = fs.readdirSync(resDir);
    icns = files.find((f) => /appicon\.icns$/i.test(f)) || files.find((f) => /\.icns$/i.test(f));
  } catch { /* no resources dir */ }
  if (!icns) return;
  const hash = crypto.createHash('md5').update(grp.bundle).digest('hex').slice(0, 12);
  const out = path.join(ICON_DIR, hash + '.png');
  if (fs.existsSync(out)) {
    entry.url = '/icons/' + hash + '.png';
    entry.ready = true;
    return;
  }
  execFile('sips', ['-z', '64', '64', '-s', 'format', 'png', path.join(resDir, icns), '--out', out], () => {
    if (fs.existsSync(out)) {
      entry.url = '/icons/' + hash + '.png';
      entry.ready = true;
    }
  });
}

/* ------------------------------------------------------------------ *
 *  Sampler
 * ------------------------------------------------------------------ */
let hardware = { model: os.hostname(), chip: null, memLabel: null };
let prevCpuTime = new Map(); // pid → cumulative cpu seconds
let prevSampleT = Date.now();
let lastPayload = null;
let lastPayloadTime = 0;
let lastStatus = null;
let sampleCount = 0;
let sampleInFlight = null;
let pendingFastSample = false;
let lastTopProcs = new Map(); // pid → { mem, cpu } from most recent valid `top`
let lastTopCpu = { user: 0, sys: 0, idle: 100, total: 0 };
let lastKernelCpu = 0; // raw %CPU for PID 0 from most recent 2-sample `top`
let lastTopCpuT = 0;
let lastFullSampleTime = 0;
let lastSnapshotReq = 0;
let prevHostCpus = os.cpus();
let lastDiskMbps = 0;
let lastDiskT = 0;
const clients = new Set();

// Network: `netstat -ib` can take seconds on machines with many interfaces,
// so it runs in the background and never blocks the 1s sampling cadence.
// The rate is computed over the real elapsed time between completions.
let netCounters = null; // { ib, ob, t }
let netRate = { down: 0, up: 0 };
let netRateReady = false;
let netBusy = false;
let lastBattOut = null;
let lastBattT = 0;
// GPU: cumulative per-client accumulatedGPUTime from the previous tick (the
// delta over the real interval is utilization). Apple Silicon only — on other
// machines ioreg returns nothing and the card shows "—".
let prevGpu = new Map();
let lastGpuT = 0;
let gpuPct = null;
let lastGpuMem = null;
let gpuHw = { name: null, cores: 0, mgpus: 1 };
let eCoreCount = 0;
try {
  eCoreCount = parseInt(execFileSync('/usr/sbin/sysctl', ['-n', 'hw.perflevel1.logicalcpu'], { encoding: 'utf8' }).trim(), 10) || 0;
} catch {}
let lastClusterLoads = { eCores: null, pCores: null };
let lastTherm = { level: 0, state: 'nominal', cpu: null, min: null, max: null };
let lastCpuTemp = null;
let lastCpuTempT = 0;
// The machine's observed CPU temperature range (°C) since the sampler started.
// The UIs scale the colour of a reading on it, so the ramp is machine-specific.
let thermalMin = null;
let thermalMax = null;
let thermalProc = null;
let thermalBuf = '';
let thermalBin = null;
let compilingThermal = false;

function getThermalBin() {
  if (thermalBin && fs.existsSync(thermalBin)) return thermalBin;
  const candidates = [
    process.env.PULSE_THERMAL_BIN,
    path.join(__dirname, '..', 'MacOS', 'pulse-thermal'),
    path.join(__dirname, 'dist', 'Pulse.app', 'Contents', 'MacOS', 'pulse-thermal'),
    path.join(__dirname, 'pulse-thermal'),
    path.join(PULSE_DIR, 'pulse-thermal'),
  ].filter(Boolean);
  for (const c of candidates) {
    if (fs.existsSync(c)) { thermalBin = c; return thermalBin; }
  }
  const src = path.join(__dirname, 'app', 'pulse-thermal.c');
  if (!compilingThermal && fs.existsSync(src)) {
    compilingThermal = true;
    const target = path.join(PULSE_DIR, 'pulse-thermal');
    try { fs.mkdirSync(PULSE_DIR, { recursive: true }); } catch {}
    execFile('/usr/bin/clang', ['-O2', src, '-o', target, '-framework', 'CoreFoundation', '-framework', 'IOKit'], (err) => {
      compilingThermal = false;
      if (!err && fs.existsSync(target)) thermalBin = target;
    });
  }
  return null;
}

function ingestThermalLine(line) {
  const parsed = parseThermalJson(line);
  if (parsed && typeof parsed.cpu === 'number') {
    lastCpuTemp = parsed.cpu;
    lastCpuTempT = Date.now();
    thermalMin = thermalMin == null ? parsed.cpu : Math.min(thermalMin, parsed.cpu);
    thermalMax = thermalMax == null ? parsed.cpu : Math.max(thermalMax, parsed.cpu);
  }
}

function kickThermal() {
  if (thermalProc) return;
  const bin = getThermalBin();
  if (!bin) return;
  try {
    const child = spawn(bin, ['--watch', '2500'], { stdio: ['pipe', 'pipe', 'ignore'] });
    thermalProc = child;
    thermalBuf = '';
    child.stdout.setEncoding('utf8');
    child.stdout.on('data', (chunk) => {
      thermalBuf += chunk;
      let nl;
      while ((nl = thermalBuf.indexOf('\n')) !== -1) {
        const line = thermalBuf.slice(0, nl).trim();
        thermalBuf = thermalBuf.slice(nl + 1);
        if (line) ingestThermalLine(line);
      }
    });
    const clear = () => {
      if (thermalProc === child) thermalProc = null;
    };
    child.on('error', clear);
    child.on('close', clear);
    if (typeof child.unref === 'function') child.unref();
  } catch {
    thermalProc = null;
  }
}

function kickNetstat() {
  if (netBusy || (netCounters && Date.now() - netCounters.t < 4500)) return;
  netBusy = true;
  run('netstat', ['-ib'], 10000).then((out) => {
    netBusy = false;
    if (!out) return; // never overwrite counters with 0 on a timeout
    const n = parseNetstat(out);
    if (n.ib === 0 && n.ob === 0 && netCounters) return;
    const now = Date.now();
    if (netCounters) {
      const dt = Math.max((now - netCounters.t) / 1000, 0.5);
      netRate.down = Math.max(0, (n.ib - netCounters.ib) / dt);
      netRate.up = Math.max(0, (n.ob - netCounters.ob) / dt);
      netRateReady = true;
    }
    netCounters = { ib: n.ib, ob: n.ob, t: now };
  });
}

function triggerSample(fast = false) {
  if (sampleInFlight) {
    if (fast) pendingFastSample = true;
    return sampleInFlight;
  }
  sampleInFlight = sample(fast).finally(() => {
    sampleInFlight = null;
    if (pendingFastSample) {
      pendingFastSample = false;
      triggerSample(true).catch(() => {});
    }
  });
  return sampleInFlight;
}

async function sample(fast = false) {
  // First sample (or an explicit on-demand refresh) skips the 1s sleep window in
  // top/iostat and uses single-shot `top -F -l 1` (~250ms) so the UI immediately
  // gets real phys_footprint memory without waiting >1s. On regular ticks, run
  // the 1s window commands FIRST and read ps/vm_stat/sysctl/pmset right as that
  // window finishes — so every metric in the snapshot is <30ms fresh when sent.
  const useFast = fast || sampleCount++ === 0;
  const activeViewer = useFast || clients.size > 0 || (Date.now() - lastSnapshotReq < 3000);
  refreshUiMtime();
  kickNetstat(); // background — never blocks the sample
  kickThermal(); // background — never blocks the sample

  let topOut = null, iostatOut = null;
  let psMain, psArgs, vmOut, sysOut, battOut, gpuOut, accelOut;
  const needBatt = !lastBattOut || Date.now() - lastBattT >= 4500;
  if (useFast) {
    [psMain, psArgs, vmOut, sysOut, topOut, battOut, gpuOut, accelOut] = await Promise.all([
      run('ps', ['-axo', 'pid=,ppid=,user=,time=,pcpu=,rss=,vsz=,stat=,etime=,comm=']),
      run('ps', ['-axo', 'pid=,args=']),
      run('vm_stat'),
      run('sysctl', ['hw.memsize', 'hw.ncpu', 'vm.swapusage', 'kern.boottime']),
      run('top', ['-F', '-l', '1', '-n', '2000', '-o', 'mem', '-stats', 'pid,cpu,mem'], 4000),
      needBatt ? run('pmset', ['-g', 'batt', '-g', 'therm']) : Promise.resolve(lastBattOut),
      run('ioreg', ['-r', '-l', '-c', 'AGXDeviceUserClient'], 4000),
      run('ioreg', ['-r', '-d', '1', '-c', 'IOAccelerator'], 4000),
    ]);
  } else if (activeViewer) {
    [topOut, iostatOut] = await Promise.all([
      run('top', ['-F', '-l', '2', '-n', '2000', '-o', 'mem', '-stats', 'pid,cpu,mem', '-s', '1'], 6000),
      run('iostat', ['-d', '-c', '2', '-w', '1'], 6000),
    ]);
    [psMain, psArgs, vmOut, sysOut, battOut, gpuOut, accelOut] = await Promise.all([
      run('ps', ['-axo', 'pid=,ppid=,user=,time=,pcpu=,rss=,vsz=,stat=,etime=,comm=']),
      run('ps', ['-axo', 'pid=,args=']),
      run('vm_stat'),
      run('sysctl', ['hw.memsize', 'hw.ncpu', 'vm.swapusage', 'kern.boottime']),
      needBatt ? run('pmset', ['-g', 'batt', '-g', 'therm']) : Promise.resolve(lastBattOut),
      run('ioreg', ['-r', '-l', '-c', 'AGXDeviceUserClient'], 4000),
      run('ioreg', ['-r', '-d', '1', '-c', 'IOAccelerator'], 4000),
    ]);
  } else {
    // Background menu-bar mode (no open dashboard): skip `top` (which walks
    // ~576k VM map entries in the kernel for ~0.43s sys CPU/s) and `iostat`.
    // Sleep 1s to preserve the 1s delta window and read system CPU in-process
    // via os.cpus() (host_processor_info).
    await new Promise((r) => setTimeout(r, 1000));
    [psMain, psArgs, vmOut, sysOut, battOut, gpuOut, accelOut] = await Promise.all([
      run('ps', ['-axo', 'pid=,ppid=,user=,time=,pcpu=,rss=,vsz=,stat=,etime=,comm=']),
      run('ps', ['-axo', 'pid=,args=']),
      run('vm_stat'),
      run('sysctl', ['hw.memsize', 'hw.ncpu', 'vm.swapusage', 'kern.boottime']),
      needBatt ? run('pmset', ['-g', 'batt', '-g', 'therm']) : Promise.resolve(lastBattOut),
      run('ioreg', ['-r', '-l', '-c', 'AGXDeviceUserClient'], 4000),
      run('ioreg', ['-r', '-d', '1', '-c', 'IOAccelerator'], 4000),
    ]);
  }
  if (needBatt && battOut) { lastBattOut = battOut; lastBattT = Date.now(); }
  const curCpuTemp = Date.now() - lastCpuTempT < 15000 ? lastCpuTemp : null;
  if (battOut || curCpuTemp !== lastTherm.cpu) {
    // min/max are sampler-lifetime state, not pmset-derived — attach, don't parse.
    lastTherm = { ...parseTherm(battOut || lastBattOut, curCpuTemp), min: thermalMin, max: thermalMax };
  }
  if (accelOut) {
    const gm = parseGpuMem(accelOut);
    if (gm !== null) lastGpuMem = gm;
  }

  // Never overwrite live data with empty/zero parser fallbacks if a core tool failed.
  if (!psMain || !vmOut || !sysOut) return;

  const sysc = parseSysctl(sysOut);
  const cores = sysc.cores;
  const psNow = Date.now();
  // Floor the window at 0.2s so a stalled loop / clock jump can't produce
  // absurd CPU values from a tiny denominator.
  const dt = Math.max((psNow - prevSampleT) / 1000, 0.2);
  prevSampleT = psNow;

  const curHostCpus = os.cpus();
  const hostCpu = computeHostCpuDelta(prevHostCpus, curHostCpus);
  if (hostCpu) {
    lastClusterLoads = computeCoreClusterLoads(prevHostCpus, curHostCpus, eCoreCount);
    prevHostCpus = curHostCpus;
  } else if (lastClusterLoads.eCores === null && eCoreCount > 0) {
    const zeroCpus = curHostCpus.map(() => ({ times: { user: 0, nice: 0, sys: 0, idle: 0, irq: 0 } }));
    lastClusterLoads = computeCoreClusterLoads(zeroCpus, curHostCpus, eCoreCount);
  }
  const clusterLoads = lastClusterLoads;

  // ---- processes + real-time CPU (delta of cumulative cpu time) ----
  const procs = parsePsMain(psMain);
  if (!procs.size) return;
  const argsMap = parsePsArgs(psArgs);
  if (topOut) {
    const parsedTop = parseTopProcs(topOut);
    if (parsedTop.size) {
      lastTopProcs = parsedTop;
      lastFullSampleTime = Date.now();
    }
    // The `CPU usage:` line (and PID 0's %CPU) are RATES: with a single-shot
    // sample (-l 1 fast path) they reflect average-SINCE-BOOT / 0, not current
    // load — only the 2nd sample of `-l 2` is a real window. Never let the fast
    // path overwrite the last real window.
    if (!useFast && topOut.includes('CPU usage:')) {
      lastTopCpu = parseTop(topOut);
      lastKernelCpu = parsedTop.get(0)?.cpu || 0;
      lastTopCpuT = Date.now();
    } else if (hostCpu) {
      lastTopCpu = hostCpu;
      lastTopCpuT = Date.now();
    }
  } else if (hostCpu) {
    lastTopCpu = hostCpu;
    lastTopCpuT = Date.now();
  }
  if (iostatOut) { lastDiskMbps = parseIostat(iostatOut); lastDiskT = Date.now(); }

  // ---- GPU (Apple Silicon, root-free; see docs/gotchas.md) ----
  // Delta of cumulative accumulatedGPUTime over the real interval, normalized
  // by the number of MGPU units. The first tick only establishes the baseline.
  if (gpuOut != null) {
    const now = parseIoregGpu(gpuOut);
    if (now.size) {
      if (prevGpu.size) {
        const gdt = Math.max((psNow - lastGpuT) / 1000, 0.2);
        let dNs = 0;
        for (const [pid, cur] of now) {
          const prev = prevGpu.get(pid);
          if (prev == null || cur.ns < prev.ns) continue; // counter reset (client re-registered)
          dNs += cur.ns - prev.ns;
        }
        gpuPct = Math.min(100, (dNs / 1e9 / gdt / gpuHw.mgpus) * 100);
      }
      lastGpuT = psNow;
      prevGpu = now;
    }
  }
  const topProcs = lastTopProcs;
  const seen = new Set();
  for (const p of procs.values()) {
    seen.add(p.pid);
    const prev = prevCpuTime.get(p.pid);
    if (prev !== undefined && p.cpuTime >= prev) {
      p.cpu = ((p.cpuTime - prev) / dt) * 100 / cores; // % of TOTAL cpu
    } else {
      p.cpu = p.pcpu / cores; // new process: lifetime average, % of total
    }
    p.cpu = Math.max(0, p.cpu);
    prevCpuTime.set(p.pid, p.cpuTime);
    p.args = argsMap.get(p.pid) || p.exe;
    p.name = path.basename(p.exe) || 'unknown';
    // Physical footprint (top) — the Activity Monitor number — with ps RSS as
    // the fallback for pids top didn't list (sub-MB tail beyond top-2000).
    p.mem = topProcs.get(p.pid)?.mem ?? p.rss * 1024;
  }
  for (const pid of prevCpuTime.keys()) if (!seen.has(pid)) prevCpuTime.delete(pid);
  for (const pid of lastTopProcs.keys()) if (pid > 0 && !seen.has(pid)) lastTopProcs.delete(pid);
  // BSD `ps` never lists PID 0 (`kernel_task`), whereas `top` does — surface it
  // so kernel CPU/memory load shows up in the panels like Activity Monitor.
  const k = topProcs.get(0);
  if (k && !procs.has(0)) {
    const kCpu = Date.now() - lastTopCpuT < 15000 ? lastKernelCpu : 0;
    procs.set(0, {
      pid: 0, ppid: 0, user: 'root',
      cpuTime: 0, pcpu: kCpu,
      rss: Math.round(k.mem / 1024), vsz: 0, stat: 'R', etime: '—',
      exe: '/System/Library/Kernels/kernel_task',
      name: 'kernel_task', args: 'kernel_task',
      cpu: Math.max(0, kCpu / cores),
      mem: k.mem,
    });
  }

  // ---- group into apps ----
  const groups = new Map();
  for (const p of procs.values()) {
    const g = groupOf(p, procs);
    let grp = groups.get(g.key);
    if (!grp) {
      grp = {
        key: g.key, name: g.name, kind: g.kind, bundle: g.bundle,
        icon: null, cpu: 0, mem: 0, procs: 0, users: new Set(),
        mainPid: null, processes: [],
      };
      groups.set(g.key, grp);
    }
    grp.cpu += p.cpu;
    grp.mem += p.mem;
    grp.procs++;
    grp.users.add(p.user);
    grp.processes.push(p);
    // mainPid = the process whose exe sits directly in the bundle's MacOS dir
    // (the app's own binary, not helpers). Lowest pid ≈ the one that started
    // first ≈ the main process; used for the "Quit app" button.
    if (grp.bundle && p.exe.startsWith(grp.bundle + '/Contents/MacOS/')) {
      if (grp.mainPid === null || p.pid < grp.mainPid) grp.mainPid = p.pid;
    }
  }
  for (const grp of groups.values()) {
    grp.processes.sort((a, b) => b.cpu - a.cpu || b.mem - a.mem);
    const killable = grp.processes.find((p) => p.pid > 0);
    if (grp.mainPid === null && killable) grp.mainPid = killable.pid;
    ensureIcon(grp);
    const ic = iconMap.get(grp.bundle);
    grp.icon = ic && ic.ready && ic.url ? ic.url : null;
  }

  // ---- system stats ----
  const vm = parseVmStat(vmOut);
  // Rate metrics (CPU from top, MB/s from iostat) go honest-zero when the
  // backing tool has been failing long enough — same rule as the netstat
  // guard, so a stalled sampler never displays a frozen "live" number.
  const top = Date.now() - lastTopCpuT < 15000 ? lastTopCpu : { user: 0, sys: 0, idle: 100, total: 0 };
  const batt = parseBatt(battOut);
  const diskReady = lastDiskT > 0 && (Date.now() - lastDiskT < 15000);
  const diskMbps = diskReady ? lastDiskMbps : 0;

  const memTotal = sysc.memTotal;
  // Clamp: vm_stat can transiently report more free bytes than the machine has.
  const free = Math.min(vm.free, memTotal);
  const used = Math.max(0, memTotal - free);
  // Activity Monitor-style partition of `used` (its bar shows these buckets):
  // kernel-measured wired + compressor first, then the reclaimable cache
  // (file-backed + purgeable, matching AM's "Cached Files" and what `purge`
  // evicts), guarded against transient vm_stat read skew. The apps' share is
  // the absorbing residual so the four segments always sum to `used`.
  const wired = Math.min(vm.wired, used);
  const compressed = Math.min(vm.compressed, Math.max(0, used - wired));
  const cache = Math.min(vm.filebacked + vm.purgeable, Math.max(0, used - wired - compressed));
  const appsMem = Math.max(0, used - wired - compressed - cache);
  // "in use" = used − cache = Apps + Wired + Compressed (reclaimable file/purgeable
  // cache excluded, matching Activity Monitor's "Memory Used" pool concept).
  const inUse = Math.max(0, used - cache);

  let netDown = 0, netUp = 0;
  const netReady = !!(netCounters && netRateReady && (Date.now() - netCounters.t < 15000));
  if (netReady) {
    netDown = netRate.down;
    netUp = netRate.up;
  }

  const snapTime = Date.now();
  // The snapshot — the contract with public/index.html (full schema in docs/contracts.md).
  // The UI reads exactly these fields; add/rename on both sides together.
  const payload = {
    t: snapTime,
    version: VERSION,
    serverMtime: SERVER_MTIME,
    uiMtime,
    sys: {
      ...hardware,
      cores,
      memTotal,
      cpu: { ...top, temp: lastTherm.cpu, eCores: clusterLoads.eCores, pCores: clusterLoads.pCores },
      loadAvg: os.loadavg().map((v) => +v.toFixed(2)),
      mem: { free, used, apps: appsMem, wired, compressed, cache, inUse },
      // Extra vm_stat counters (bytes), informational only — NOT part of the
      // normalized `mem` segments above (the UI's bar/sum uses those). They
      // power the memory info popover: what's file cache, what the compressor
      // is packing, how much inactive pool is waiting to be compressed.
      memDetail: {
        active: vm.active, inactive: vm.inactive, speculative: vm.speculative,
        purgeable: vm.purgeable, filebacked: vm.filebacked,
        storedCompressed: vm.storedCompressed,
      },
      swap: { used: sysc.swapUsed },  // total omitted: auto-allocated on macOS, means nothing
      uptime: sysc.bootTime ? Math.max(0, Math.floor(Date.now() / 1000 - sysc.bootTime)) : 0,
      net: { down: netDown, up: netUp, ready: netReady },
      disk: { mbps: diskMbps, ready: diskReady },
      batt,
      gpu: {
        pct: gpuPct == null ? null : +gpuPct.toFixed(1),
        mem: lastGpuMem,
        name: gpuHw.name,
        cores: gpuHw.cores,
      },
      thermal: lastTherm,   // { level, state, cpu, min, max } — pmset state + observed temp range
      procCount: procs.size,
      appCount: groups.size,
    },
    apps: [...groups.values()].map((g) => ({
      key: g.key, name: g.name, kind: g.kind, bundle: g.bundle, icon: g.icon,
      cpu: g.cpu, mem: g.mem, procs: g.procs, users: [...g.users], mainPid: g.mainPid,
      processes: g.processes.map((p) => ({
        pid: p.pid, ppid: p.ppid, user: p.user, name: p.name,
        cpu: p.cpu, mem: p.mem, vsz: p.vsz * 1024, stat: p.stat, etime: p.etime,
        args: p.args, role: roleOf(p.name), desc: KNOWN[p.name] || null,
      })),
    })),
  };

  lastPayload = JSON.stringify(payload);
  lastPayloadTime = snapTime;
  if (!BOOT_TRACE.firstSnapshot) BOOT_TRACE.firstSnapshot = snapTime;

  // Status-bar layout for the menu (dropdown rows + button capsules) —
  // settings.json is a few hundred bytes, so one read per second is negligible
  // next to the ps/vm_stat fan-out.
  try {
    const sRaw = JSON.parse(fs.readFileSync(path.join(PULSE_DIR, 'settings.json'), 'utf8'));
    lastMenuRows = normalizeMenuRows(sRaw.menuRows);
    lastBarRows = normalizeBarRows(sRaw.barRows, lastMenuRows);
    lastLayoutGen = typeof sRaw.layoutGen === 'number' ? sRaw.layoutGen : 0;
  } catch { /* no/invalid settings file → keep the last known layout */ }

  // Lightweight status for the menu-bar item (avoids shipping the full snapshot).
  // Contract with app/Pulse.swift StatusController: `cpu` is the SYSTEM cpu
  // object (user/sys/idle/total from top); the rest are menu-row fields.
  const mu = process.memoryUsage();
  // netDown / netUp are the aggregate network rates (bytes/s) already computed
  // from the netstat counters above — the status payload reports them as MB/s.
  const st = {
    t: snapTime,
    serverMtime: SERVER_MTIME,
    bootTrace: BOOT_TRACE,
    memDebug: { rss: mu.rss, heapTotal: mu.heapTotal, heapUsed: mu.heapUsed, external: mu.external },
    cpu: { ...top, temp: lastTherm.cpu, eCores: clusterLoads.eCores, pCores: clusterLoads.pCores },
    loadAvg: os.loadavg().map((v) => +v.toFixed(2)),
    // AM-style: "memory used" = used − cache (Apps + Wired + Compressed;
    // reclaimable file/purgeable cache excluded)
    memPct: memTotal ? +((inUse / memTotal) * 100).toFixed(1) : 0,
    memUsed: inUse,
    memTotal,
    memPools: {
      wired,
      active: appsMem,
      compressed,
      free,
    },
    gpuPct: gpuPct == null ? null : +gpuPct.toFixed(1),
    gpuMem: lastGpuMem,
    thermal: lastTherm,      // { level, state, cpu, min, max } — cpu temp is coloured on min..max by the UIs
    net: { down: netDown, up: netUp }, // bytes/s — same scale as snapshot.sys.net; each side formats B/KB/MB/GB
    bootTime: sysc.bootTime, // epoch sec — the menu computes uptime
    menuRows: lastMenuRows,  // ordered visible row ids (settings.json) — menu layout
    barRows: lastBarRows,    // visible status-bar capsules (menu order applies)
    layoutGen: lastLayoutGen,     // settings-file revision — the app skips layouts older than its own last write
  };
  if (purgeQueue) st.purge = purgeQueue.id;  // the app shell runs the in-process prompt
  lastStatus = JSON.stringify(st);

  for (const res of clients) {
    try { res.write('data: ' + lastPayload + '\n\n'); } catch { /* client gone */ }
  }
}

/* ------------------------------------------------------------------ *
 *  Purge — the "Clear RAM" lever
 *
 *  The only supported reclamation primitive on macOS: /usr/sbin/purge
 *  (vfs_purge in the kernel) evicts clean file-backed cache pages and
 *  volatile app-purgeable pages to the free pool. It NEVER touches the
 *  compressed pool or apps' working sets, and it requires root — so we
 *  run it through osascript's native Touch ID / password dialog. Fixed
 *  command, no user input: as safe as /api/kill under the loopback-only
 *  invariant. Needs an active GUI session for the dialog to render.
 * ------------------------------------------------------------------ */

// "User canceled. (-128)" → exit 1; "Cannot complete…" variants → other codes.
const PURGE_SCRIPT =
  'do shell script "/usr/sbin/purge" with prompt "Pulse wants to clear the disk cache. '
  + 'You will be asked for Touch ID or your password." with administrator privileges';

// App mode (PULSE=1): the app shell runs the AppleScript in-process, so the
// SecurityAgent prompt is attributed to Pulse itself — branded, and offered
// Touch ID when the bundle is notarized (releases or `./app/build.sh --notarize`;
// unnotarized dev builds fall back to password-only). The server only queues
// the request and reports the result. Web mode has no app shell, so the server
// runs osascript directly (attributed to osascript — password-only).
const APP_MODE = process.env.PULSE === '1';

let purgeBusy = false;
let purgeQueue = null;  // app mode: { id, before, resolve, settled, timer }
let purgeSeq = 0;

// Run the admin-prompted purge. Resolves { ok, cancelled, error } — never rejects.
function purgeFailure(err, stderr) {
  if (!err) return { ok: true, cancelled: false };
  const s = `${stderr || ''} ${err.message || ''}`;
  if (err.code === 'ENOENT')
    return { ok: false, cancelled: false, error: 'osascript not available (macOS only)' };
  if (/user cancel(ed|led)|\(-128\)/i.test(s))
    return { ok: false, cancelled: true };
  if (err.code === 'ETIMEDOUT' || err.killed)
    return { ok: false, cancelled: false, error: 'timed out waiting for the security prompt' };
  return { ok: false, cancelled: false, error: 'the security prompt failed — a GUI session is required' };
}

// Both deltas should agree (the kernel moves evicted pages straight to the
// free pool); take the max so memory freed by other apps in the same second
// never masks the win, and the result can't go negative.
function computePurged(before, after) {
  const freed = Math.max(0, after.free - before.free);
  const cached = Math.max(0, (before.filebacked + before.purgeable) - (after.filebacked + after.purgeable));
  return Math.max(freed, cached);
}

async function doPurge() {
  const before = parseVmStat(await run('vm_stat'));
  if (APP_MODE) {
    // Queue for the app shell: it sees the id in /api/status (2s poll), runs
    // the in-process prompt, and reports back via /api/purge-result. The UI's
    // fetch stays pending until then (or the 5-min timeout below).
    const id = ++purgeSeq;
    return new Promise((resolve) => {
      purgeQueue = { id, before, resolve, settled: false,
        timer: setTimeout(() => settlePurgeQueue(id, { ok: false, error: 'timed out waiting for the Pulse app to run the purge' }), 5 * 60 * 1000) };
    });
  }
  return new Promise((resolve) => {
    execFile('/usr/bin/osascript', ['-e', PURGE_SCRIPT], { timeout: 5 * 60 * 1000 },
      (err, stdout, stderr) => {
        const fail = purgeFailure(err, stderr);
        if (!fail.ok) return resolve(fail);
        run('vm_stat').then((out) => {
          const after = parseVmStat(out);
          const cached = Math.max(0, (before.filebacked + before.purgeable) - (after.filebacked + after.purgeable));
          resolve({ ok: true, cancelled: false, freed: computePurged(before, after), cached });
        });
      });
  });
}

// App shell reported the in-process prompt outcome; finish with the before/after math.
function settlePurgeQueue(id, result) {
  const q = purgeQueue;
  if (!q || q.id !== id || q.settled) return;  // stale — already timed out or superseded
  q.settled = true;
  if (q.timer) clearTimeout(q.timer);
  run('vm_stat').then((out) => {
    const after = parseVmStat(out);
    const cached = Math.max(0, (q.before.filebacked + q.before.purgeable) - (after.filebacked + after.purgeable));
    purgeQueue = null;  // also drops the `purge` flag from /api/status
    q.resolve({ ...result, freed: computePurged(q.before, after), cached });
  });
}

/* ------------------------------------------------------------------ *
 *  HTTP server
 *
 *  /               index.html
 *  /events         SSE stream of snapshots (15s ping; client retry: 2s)
 *  /api/snapshot   last snapshot (polling fallback for the UI)
 *  /api/status     lightweight status for the menu-bar item
 *  /api/kill       POST { pid, sig: 'TERM' | 'KILL' } — safe only because we
 *                  bind 127.0.0.1 with no auth; don't change the default HOST
 *  /api/purge      POST {} → admin-prompted `purge`; app mode queues for the
 *                  app shell (in-process prompt), web mode runs osascript
 *  /api/purge-result POST { id, ok, cancelled } ← Pulse.swift (in-app outcome)
 *  /icons/*        cached app icons
 * ------------------------------------------------------------------ */
const CORS_HEADERS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
  'Access-Control-Allow-Headers': 'Content-Type',
  'Access-Control-Max-Age': '86400',
};

const server = http.createServer((req, res) => {
  for (const [k, v] of Object.entries(CORS_HEADERS)) res.setHeader(k, v);
  if (req.method === 'OPTIONS') {
    res.writeHead(204);
    res.end();
    return;
  }
  const url = (req.url || '/').split('?')[0];

  if (url === '/' || url === '/index.html') {
    fs.readFile(path.join(PUBLIC_DIR, 'index.html'), (err, buf) => {
      if (err) { res.writeHead(500); res.end('index.html missing'); return; }
      // no-store (not just no-cache): WKWebView keeps a persistent on-disk cache
      // and can serve a stale page across app launches; never let it cache this.
      res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'no-store' });
      res.end(buf);
    });
  } else if (url === '/events') {
    res.writeHead(200, {
      'Content-Type': 'text/event-stream',
      'Cache-Control': 'no-store, no-cache, must-revalidate',
      Connection: 'keep-alive',
      'X-Accel-Buffering': 'no',
    });
    res.write('retry: 1500\n\n');
    clients.add(res);
    if (lastPayload && Date.now() - lastPayloadTime < 4000) {
      res.write('data: ' + lastPayload + '\n\n');
      if (Date.now() - lastFullSampleTime > 4000) {
        triggerSample(true).catch(() => {});
      }
    } else {
      triggerSample(true).catch(() => {});
    }
    const ping = setInterval(() => { try { res.write(': ping\n\n'); } catch { /* noop */ } }, 15000);
    req.on('close', () => { clearInterval(ping); clients.delete(res); });
  } else if (url === '/api/snapshot') {
    lastSnapshotReq = Date.now();
    const wantFresh = (req.url || '').includes('fresh=1');
    const stale = !lastPayload || Date.now() - lastPayloadTime > 4000;
    const reply = () => {
      res.writeHead(200, {
        'Content-Type': 'application/json',
        'Cache-Control': 'no-store, no-cache, must-revalidate',
      });
      res.end(lastPayload || '{}');
    };
    if (wantFresh || stale) {
      triggerSample(true).catch(() => {}).finally(reply);
    } else {
      reply();
    }
  } else if (url === '/api/status') {
    // Await the fresh sample like /api/snapshot does — replying fire-and-forget
    // would hand the menu bar a minutes-old graph right after wake/stall.
    const reply = () => {
      res.writeHead(200, {
        'Content-Type': 'application/json',
        'Cache-Control': 'no-store, no-cache, must-revalidate',
      });
      res.end(lastStatus || '{}');
    };
    if (!lastStatus || Date.now() - lastPayloadTime > 5000) {
      triggerSample(true).catch(() => {}).finally(reply);
    } else {
      reply();
    }
  } else if (url === '/api/kill' && req.method === 'POST') {
    let body = '';
    req.on('data', (c) => { body += c; if (body.length > 1e4) req.destroy(); });
    req.on('end', () => {
      try {
        const { pid, sig } = JSON.parse(body || '{}');
        const p = Math.floor(+pid);
        const s = sig === 'KILL' ? 'SIGKILL' : 'SIGTERM';
        if (!Number.isFinite(p) || p <= 0) throw new Error('bad pid');
        process.kill(p, s);
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ ok: true }));
      } catch (e) {
        res.writeHead(400, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ ok: false, error: e.code === 'ESRCH' ? 'process already gone' : String(e.message || e) }));
      }
    });
  } else if (url === '/api/purge' && req.method === 'POST') {
    if (purgeBusy) {
      res.writeHead(409, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ ok: false, error: 'a purge is already in progress' }));
      return;
    }
    purgeBusy = true;
    doPurge()
      .then((r) => {
        res.writeHead(r.ok ? 200 : 400, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify(r));
      })
      .catch((e) => {
        res.writeHead(500, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ ok: false, error: String(e.message || e) }));
      })
      .finally(() => { purgeBusy = false; });
  } else if (url === '/api/purge-result' && req.method === 'POST') {
    let body = '';
    req.on('data', (c) => { body += c; if (body.length > 1e4) req.destroy(); });
    req.on('end', () => {
      try {
        const { id, ok, cancelled } = JSON.parse(body || '{}');
        const p = Math.floor(+id);
        if (purgeQueue && purgeQueue.id === p) {
          settlePurgeQueue(p, { ok: !!ok && !cancelled, cancelled: !!cancelled });
        }
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ ok: true }));
      } catch {
        res.writeHead(400, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ ok: false }));
      }
    });
  } else if (url === '/api/settings') {
    const settingsPath = path.join(PULSE_DIR, 'settings.json');
    const plistPath = path.join(os.homedir(), 'Library', 'LaunchAgents', 'local.pulse.monitor.plist');
    const loadSettings = () => {
      let raw = {};
      try { raw = JSON.parse(fs.readFileSync(settingsPath, 'utf8')) || {}; } catch { raw = {}; }
      delete raw.statusBarGraphType;
      return {
        raw,
        state: {
          version: 2,
          startAtLogin: typeof raw.startAtLogin === 'boolean' ? raw.startAtLogin : fs.existsSync(plistPath),
          closeBehavior: raw.closeBehavior === 'quit' ? 'quit' : 'background',
          keepDashboardInMemory: !!raw.keepDashboardInMemory,
          menuRows: normalizeMenuRows(raw.menuRows),
          barRows: normalizeBarRows(raw.barRows, normalizeMenuRows(raw.menuRows)),
          layoutGen: typeof raw.layoutGen === 'number' ? raw.layoutGen : 0,
          daemonStatus: fs.existsSync(plistPath) ? 'active' : 'off',
        },
      };
    };
    if (req.method === 'GET') {
      res.writeHead(200, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' });
      res.end(JSON.stringify(loadSettings().state));
    } else if (req.method === 'POST') {
      let body = '';
      req.on('data', (c) => { body += c; if (body.length > 1e4) req.destroy(); });
      req.on('end', () => {
        try {
          const patch = JSON.parse(body || '{}');
          const { raw, state } = loadSettings();
          if (typeof patch.startAtLogin === 'boolean') state.startAtLogin = patch.startAtLogin;
          if (patch.closeBehavior === 'quit' || patch.closeBehavior === 'background') state.closeBehavior = patch.closeBehavior;
          if (typeof patch.keepDashboardInMemory === 'boolean') state.keepDashboardInMemory = patch.keepDashboardInMemory;
          if (patch.menuRows !== undefined) state.menuRows = normalizeMenuRows(patch.menuRows);
          if (patch.barRows !== undefined) state.barRows = normalizeBarRows(patch.barRows, state.menuRows);
          state.layoutGen = (typeof raw.layoutGen === 'number' ? raw.layoutGen : 0) + 1; // any settings write advances the revision
          const merged = {
            ...raw,
            version: 2,
            startAtLogin: state.startAtLogin,
            closeBehavior: state.closeBehavior,
            keepDashboardInMemory: state.keepDashboardInMemory,
            menuRows: state.menuRows,
            barRows: state.barRows,
            layoutGen: state.layoutGen,
          };
          fs.mkdirSync(PULSE_DIR, { recursive: true });
          fs.writeFileSync(settingsPath, JSON.stringify(merged, null, 2) + '\n');
          res.writeHead(200, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({ ok: true, ...state }));
        } catch (e) {
          res.writeHead(400, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({ ok: false, error: String(e.message || e) }));
        }
      });
    } else {
      res.writeHead(405); res.end();
    }
  } else if (url.startsWith('/icons/')) {
    const f = path.join(ICON_DIR, path.basename(url));
    if (!f.startsWith(ICON_DIR)) { res.writeHead(400); res.end(); return; }
    fs.readFile(f, (err, buf) => {
      if (err) { res.writeHead(404); res.end(); return; }
      res.writeHead(200, { 'Content-Type': 'image/png', 'Cache-Control': 'public, max-age=86400' });
      res.end(buf);
    });
  } else {
    res.writeHead(404, { 'Content-Type': 'text/plain' });
    res.end('not found');
  }
});

/* ------------------------------------------------------------------ *
 *  Main loop
 * ------------------------------------------------------------------ */
let actualPort = PORT;

function parsePortFile(text) {
  if (!text) return null;
  const lines = String(text).trim().split(/\r?\n/);
  const port = Math.floor(+lines[0]);
  if (!Number.isFinite(port) || port <= 0 || port >= 65536) return null;
  let pid = null;
  if (lines.length > 1 && lines[1].trim() !== '') {
    const p = Math.floor(+lines[1].trim());
    if (Number.isFinite(p) && p > 0) pid = p;
  }
  return { port, pid };
}

function isPidAlive(pid) {
  if (!pid || pid <= 0) return false;
  try { process.kill(pid, 0); return true; }
  catch (e) { return !!(e && e.code === 'EPERM'); }
}

function canWritePortFile(existingText, selfPid, checkAlive = isPidAlive) {
  if (!existingText) return true;
  const parsed = parsePortFile(existingText);
  if (!parsed || !parsed.pid) return true;
  if (parsed.pid === selfPid) return true;
  return !checkAlive(parsed.pid);
}

const skipPortFile = () =>
  process.env.PULSE_RACE === '1'
  || (process.env.PULSE_SELFTEST === '1' && !process.env.PULSE_PORT_FILE);

// Tell the world where we are: a stdout line for the app shell, plus a pid-owned
// port file (`<port>\n<pid>\n`) so a later launch (app or web) can find and reuse this server.
function announcePort() {
  console.log(`PULSE_LISTENING=${actualPort}`);
  if (skipPortFile()) return; // don't clobber a live session's port file
  try {
    fs.mkdirSync(path.dirname(PORT_FILE), { recursive: true });
    let existing = null;
    try { existing = fs.readFileSync(PORT_FILE, 'utf8'); } catch { /* absent */ }
    if (canWritePortFile(existing, process.pid)) {
      fs.writeFileSync(PORT_FILE, `${actualPort}\n${process.pid}\n`);
    }
  } catch { /* non-fatal */ }
}

for (const sig of ['SIGINT', 'SIGTERM']) {
  process.on(sig, () => process.exit(0));
}

// Remove the port file on ANY exit path (signals, watchdog, crash) so a stale
// file never points at a dead server, and only if BOTH port and pid match self.
process.on('exit', () => {
  if (skipPortFile()) return;
  try {
    const parsed = parsePortFile(fs.readFileSync(PORT_FILE, 'utf8'));
    if (parsed && parsed.port === actualPort && (!parsed.pid || parsed.pid === process.pid)) {
      fs.unlinkSync(PORT_FILE);
    }
  } catch { /* file already gone */ }
});

function consumePreferredPort() {
  if (PORT !== 0 || process.env.PULSE_SELFTEST === '1') return PORT;
  const f = path.join(PULSE_DIR, 'preferred-port');
  try {
    const p = Math.floor(+fs.readFileSync(f, 'utf8').trim());
    fs.unlinkSync(f);
    if (Number.isFinite(p) && p > 0 && p < 65536) return p;
  } catch { /* no preferred port */ }
  return 0;
}

(async function main() {
  // Start serving immediately — hardware identity (system_profiler, 1-3s) loads in
  // the background and fills in on the next tick.
  const bindPort = consumePreferredPort();
  let triedFallback = false;
  server.on('error', (err) => {
    if (err && err.code === 'EADDRINUSE' && process.env.PULSE === '1' && !triedFallback && bindPort !== 0) {
      triedFallback = true;
      server.listen(0, HOST);
      return;
    }
    console.error(err);
    process.exit(1);
  });
  server.listen(bindPort, HOST, () => {
    actualPort = server.address().port;
    BOOT_TRACE.listen = Date.now();
    console.log(`\n  Pulse is running →  http://${HOST}:${actualPort}\n`);
    announcePort();
  });
  getHardware().then((h) => {
    hardware = h;
    console.log(`  ${hardware.model} · ${hardware.chip || ''} · ${hardware.memLabel || ''}\n`);
  });
  // GPU identity (name / core count / MGPU units) — best effort, one-shot.
  (async function probeGpu() {
    try {
      const tree = await run('ioreg', ['-p', 'IOService'], 5000);
      const cls = new Set();
      for (const m of (tree || '').matchAll(/<class ([A-Za-z0-9]+Accelerator[A-Za-z0-9]*)/g)) cls.add(m[1]);
      const accel = [...cls].find((c) => c.startsWith('AGX')) || [...cls][0];
      if (!accel) return; // no IOKit GPU node (e.g. headless) — gpu stays unavailable
      const node = await run('ioreg', ['-r', '-l', '-c', accel], 5000);
      const g = (re) => { const m = (node || '').match(re); return m ? m[1] : null; };
      gpuHw = {
        name: g(/"model" = "([^"]+)"/) || null,
        cores: +(g(/"gpu-core-count" = "?(\d+)"?/)) || 0,
        mgpus: +(g(/"num_mgpus"=(\d+)/)) || 1,
      };
      if (gpuHw.name) console.log(`  GPU: ${gpuHw.name} (${gpuHw.cores} cores, ${gpuHw.mgpus} mgpu)`);
    } catch { /* leave defaults — the card shows "—" */ }
  })();
  await triggerSample(true); // fast first sample (~250ms) — awaited so it never overlaps loop()
  (function loop() {
    const started = Date.now();
    triggerSample(false).catch(() => {}).finally(() => {
      setTimeout(loop, Math.max(50, INTERVAL - (Date.now() - started)));
    });
  })();
  console.log(`  sampling every ${INTERVAL}ms · press Ctrl+C to stop`);
})().catch((e) => {
  console.error(e);
  process.exit(1);
});
