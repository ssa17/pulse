#!/usr/bin/env node
/**
 * Pulse — real-time macOS resource dashboard.
 *
 * Zero-dependency Node.js backend:
 *  - samples the whole system every second (ps, vm_stat, sysctl, top, netstat, iostat, pmset)
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
const { execFile, execFileSync } = require('child_process');

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
// Shared state lives in ~/.pulse (port file + icon cache) — never inside the app
// bundle, which should stay immutable.
const PULSE_DIR = path.join(os.homedir(), '.pulse');
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

// Show up nicely in Activity Monitor / ps when running as the app's backend.
process.title = 'Pulse';

// Safety net: when launched by the Pulse app, exit if our parent (the app) dies,
// so a crashed/killed app never leaves an orphaned backend behind.
// (process.ppid is cached at startup; signal 0 is the live existence check.)
if (process.env.PULSE === '1') {
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
  const r = { free: 0, active: 0, inactive: 0, wired: 0, purgeable: 0, compressed: 0 };
  if (!out) return r;
  const page = +(out.match(/page size of (\d+)/) || [])[1] || 16384;
  const grab = (re) => { const m = out.match(re); return m ? +m[1] * page : 0; };
  r.free = grab(/Pages free:\s*(\d+)/);
  r.active = grab(/Pages active:\s*(\d+)/);
  r.inactive = grab(/Pages inactive:\s*(\d+)/);
  r.wired = grab(/Pages wired down:\s*(\d+)/);
  r.purgeable = grab(/Pages purgeable:\s*(\d+)/);
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
  const r = { memTotal: 0, cores: os.cpus().length, swapTotal: 0, swapUsed: 0, load: [0, 0, 0], bootTime: 0 };
  if (!out) return r;
  const g = (re) => { const m = out.match(re); return m ? m[1] : null; };
  r.memTotal = +(g(/hw\.memsize:\s*(\d+)/)) || 0;
  r.cores = +(g(/hw\.ncpu:\s*(\d+)/)) || r.cores;
  const sw = out.match(/vm\.swapusage:.*?total = ([\d.]+)([KMGT]?)[B]?.*?used = ([\d.]+)([KMGT]?)[B]?/);
  if (sw) { r.swapTotal = parseSize(sw[1], sw[2]); r.swapUsed = parseSize(sw[3], sw[4]); }
  const la = out.match(/vm\.loadavg:\s*\{\s*([\d.]+)\s+([\d.]+)\s+([\d.]+)\s*\}/);
  if (la) r.load = [+la[1], +la[2], +la[3]];
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

/** pmset -g batt → e.g. " -InternalBattery-0 (id=…) 86%; charging; 2:31 remaining" */
function parseBatt(out) {
  const r = { pct: null, charging: false, time: null };
  if (!out) return r;
  const m = out.match(/(\d+)\s*%;\s*([a-zA-Z ]+?);(?:\s*([\d:]+)\s*remaining)?/);
  if (m) {
    r.pct = +m[1];
    r.charging = /charging/i.test(m[2]);
    r.time = m[3] || null;
  }
  return r;
}

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
  'com.apple.WebKit.WebContent': 'Safari — web page process',
  'com.apple.WebKit.GPU': 'Safari — GPU process',
  'com.apple.WebKit.Networking': 'Safari — networking process',
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
let lastStatus = null;
let sampleCount = 0;
const clients = new Set();

// Network: `netstat -ib` can take seconds on machines with many interfaces,
// so it runs in the background and never blocks the 1s sampling cadence.
// The rate is computed over the real elapsed time between completions.
let netCounters = null; // { ib, ob, t }
let netRate = { down: 0, up: 0 };
let netBusy = false;

function kickNetstat() {
  if (netBusy) return;
  netBusy = true;
  run('netstat', ['-ib'], 10000).then((out) => {
    netBusy = false;
    const n = parseNetstat(out);
    const now = Date.now();
    if (netCounters) {
      const dt = Math.max((now - netCounters.t) / 1000, 0.5);
      netRate.down = Math.max(0, (n.ib - netCounters.ib) / dt);
      netRate.up = Math.max(0, (n.ob - netCounters.ob) / dt);
    }
    netCounters = { ib: n.ib, ob: n.ob, t: now };
  });
}

async function sample() {
  const t0 = Date.now();
  // First sample skips the 1s-window commands (top, iostat) so the UI gets
  // real data almost instantly; they fill in on the next tick.
  const first = sampleCount++ === 0;
  const [psMain, psArgs, vmOut, sysOut, topOut, iostatOut, battOut] = await Promise.all([
    run('ps', ['-axo', 'pid=,ppid=,user=,time=,pcpu=,rss=,vsz=,stat=,etime=,comm=']),
    run('ps', ['-axo', 'pid=,args=']),
    run('vm_stat'),
    run('sysctl', ['hw.memsize', 'hw.ncpu', 'vm.swapusage', 'vm.loadavg', 'kern.boottime']),
    first ? Promise.resolve(null) : run('top', ['-l', '2', '-n', '0', '-s', '1'], 6000),
    first ? Promise.resolve(null) : run('iostat', ['-d', '-c', '2', '-w', '1'], 6000),
    run('pmset', ['-g', 'batt']),
  ]);
  kickNetstat(); // background — never blocks the sample

  const sysc = parseSysctl(sysOut);
  const cores = sysc.cores;
  // Floor the window at 0.2s so a stalled loop / clock jump can't produce
  // absurd CPU values from a tiny denominator.
  const dt = Math.max((t0 - prevSampleT) / 1000, 0.2);
  prevSampleT = t0;

  // ---- processes + real-time CPU (delta of cumulative cpu time) ----
  const procs = parsePsMain(psMain);
  const argsMap = parsePsArgs(psArgs);
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
    p.mem = p.rss * 1024;
  }
  for (const pid of prevCpuTime.keys()) if (!seen.has(pid)) prevCpuTime.delete(pid);

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
    if (grp.mainPid === null && grp.processes.length) grp.mainPid = grp.processes[0].pid;
    ensureIcon(grp);
    const ic = iconMap.get(grp.bundle);
    grp.icon = ic && ic.ready && ic.url ? ic.url : null;
  }

  // ---- system stats ----
  const vm = parseVmStat(vmOut);
  const top = parseTop(topOut);
  const batt = parseBatt(battOut);
  const diskMbps = parseIostat(iostatOut);

  const sumRss = [...groups.values()].reduce((a, g) => a + g.mem, 0);
  const memTotal = sysc.memTotal;
  // Clamp: vm_stat can transiently report more free bytes than the machine has.
  const free = Math.min(vm.free, memTotal);
  const used = Math.max(0, memTotal - free);
  // segments normalized so they always sum to `used` (RSS double-counts shared pages)
  const appsMem = Math.min(sumRss, used);
  let rem = used - appsMem;
  const wired = Math.min(vm.wired, rem); rem -= wired;
  const compressed = Math.min(vm.compressed, rem); rem -= compressed;
  const cache = Math.max(0, rem);

  let netDown = 0, netUp = 0;
  if (netCounters) {
    netDown = netRate.down;
    netUp = netRate.up;
  }

  // The snapshot — the contract with public/index.html (full schema in docs/contracts.md).
  // The UI reads exactly these fields; add/rename on both sides together.
  const payload = {
    t: t0,
    version: VERSION,
    sys: {
      ...hardware,
      hostname: os.hostname(),
      cores,
      memTotal,
      cpu: top,
      mem: { free, used, apps: appsMem, wired, compressed, cache },
      swap: { total: sysc.swapTotal, used: sysc.swapUsed },
      load: sysc.load,
      uptime: sysc.bootTime ? Math.max(0, Math.floor(Date.now() / 1000 - sysc.bootTime)) : 0,
      net: { down: netDown, up: netUp },
      disk: { mbps: diskMbps },
      batt,
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

  // Lightweight status for the menu-bar item (avoids shipping the full snapshot).
  // Contract with app/Pulse.swift StatusController: `cpu` is the SYSTEM cpu
  // object (user/sys/idle/total from top); `topCpu`/`topMem` are top apps.
  const appsArr = payload.apps;
  if (appsArr.length) {
    const topCpu = appsArr.reduce((a, b) => (b.cpu > a.cpu ? b : a));
    const topMem = appsArr.reduce((a, b) => (b.mem > a.mem ? b : a));
    lastStatus = JSON.stringify({
      cpu: top,
      memPct: memTotal ? +((used / memTotal) * 100).toFixed(1) : 0,
      memUsed: used,
      memTotal,
      topCpu: { name: topCpu.name, cpu: +topCpu.cpu.toFixed(1) },
      topMem: { name: topMem.name, mem: topMem.mem },
    });
  }

  for (const res of clients) {
    try { res.write('data: ' + lastPayload + '\n\n'); } catch { /* client gone */ }
  }
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
 *  /icons/*        cached app icons
 * ------------------------------------------------------------------ */
const server = http.createServer((req, res) => {
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
      'Cache-Control': 'no-cache',
      Connection: 'keep-alive',
      'X-Accel-Buffering': 'no',
    });
    res.write('retry: 2000\n\n');
    if (lastPayload) res.write('data: ' + lastPayload + '\n\n');
    clients.add(res);
    const ping = setInterval(() => { try { res.write(': ping\n\n'); } catch { /* noop */ } }, 15000);
    req.on('close', () => { clearInterval(ping); clients.delete(res); });
  } else if (url === '/api/snapshot') {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(lastPayload || '{}');
  } else if (url === '/api/status') {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(lastStatus || '{}');
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

// Tell the world where we are: a stdout line for the app shell, plus a port file
// so a later launch (app or web) can find and reuse this server.
function announcePort() {
  console.log(`PULSE_LISTENING=${actualPort}`);
  try {
    fs.mkdirSync(PULSE_DIR, { recursive: true });
    fs.writeFileSync(path.join(PULSE_DIR, 'port'), String(actualPort) + '\n');
  } catch { /* non-fatal */ }
}

for (const sig of ['SIGINT', 'SIGTERM']) {
  process.on(sig, () => process.exit(0));
}

// Remove the port file on ANY exit path (signals, watchdog, crash) so a stale
// file never points at a dead server. Synchronous fs is allowed in exit handlers.
process.on('exit', () => {
  try {
    const f = path.join(PULSE_DIR, 'port');
    if (fs.readFileSync(f, 'utf8').trim() === String(actualPort)) fs.unlinkSync(f);
  } catch { /* file already gone */ }
});

(async function main() {
  // Start serving immediately — hardware identity (system_profiler, 1-3s) loads in
  // the background and fills in on the next tick.
  server.listen(PORT, HOST, () => {
    actualPort = server.address().port;
    console.log(`\n  Pulse is running →  http://${HOST}:${actualPort}\n`);
    announcePort();
  });
  getHardware().then((h) => {
    hardware = h;
    console.log(`  ${hardware.model} · ${hardware.chip || ''} · ${hardware.memLabel || ''}\n`);
  });
  sample(); // first sample immediately (fast path: skips 1s-window commands)
  (function loop() {
    const started = Date.now();
    sample().catch(() => {}).finally(() => {
      setTimeout(loop, Math.max(50, INTERVAL - (Date.now() - started)));
    });
  })();
  console.log(`  sampling every ${INTERVAL}ms · press Ctrl+C to stop`);
})().catch((e) => {
  console.error(e);
  process.exit(1);
});
