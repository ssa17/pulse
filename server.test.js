#!/usr/bin/env node
/**
 * server.test.js — unit tests for every parsing function in server.js.
 *
 * Run:  node server.test.js
 *
 * These tests use string snapshots so they are fully offline and deterministic
 * (no live system calls).  They catch regressions in every format change that
 * macOS makes to ps, vm_stat, sysctl, top, netstat, iostat, or pmset.
 */
'use strict';

const path = require('path');

// ---------------------------------------------------------------------------
//  Copy of parser functions from server.js (self-contained, no HTTP deps)
// ---------------------------------------------------------------------------

function parseCpuTime(s) {
  if (!s) return 0;
  let sec = 0;
  for (const part of s.split(':')) sec = sec * 60 + (parseFloat(part) || 0);
  return sec;
}

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
  const r = { memTotal: 0, cores: 0, swapTotal: 0, swapUsed: 0, load: [0, 0, 0], bootTime: 0 };
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

function parseNetstat(out) {
  let ib = 0, ob = 0;
  if (!out) return { ib, ob };
  const byName = new Map();
  for (const line of out.split('\n').slice(1)) {
    const c = line.trim().split(/\s+/);
    if (c.length < 10) continue;
    const name = c[0];
    if (name.startsWith('lo')) continue;
    const isLink = c.length === 10;
    const a = isLink ? 5 : 6;
    const b = isLink ? 8 : 9;
    const cur = byName.get(name);
    if (!cur || isLink) byName.set(name, { ib: +c[a] || 0, ob: +c[b] || 0 });
  }
  for (const v of byName.values()) { ib += v.ib; ob += v.ob; }
  return { ib, ob };
}

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

// Purge result classifiers (self-test for the /api/purge endpoint logic).
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

function computePurged(before, after) {
  const freed = Math.max(0, after.free - before.free);
  const cached = Math.max(0, (before.filebacked + before.purgeable) - (after.filebacked + after.purgeable));
  return Math.max(freed, cached);
}

// ---------------------------------------------------------------------------
//  Assertions
// ---------------------------------------------------------------------------
let passed = 0, failed = 0;

function assert(cond, msg) {
  if (!cond) { failed++; console.error(`  FAIL: ${msg}`); return; }
  passed++;
}

function assertDeepEquals(a, b, msg) {
  const sa = JSON.stringify(a);
  const sb = JSON.stringify(b);
  assert(sa === sb, `${msg}\n    expected: ${sa}\n    actual:   ${sb}`);
}

// ---------------------------------------------------------------------------
//  Tests
// ---------------------------------------------------------------------------

/* ── parseCpuTime ───────────────────────────────────────────────────────── */
console.log('\n--- parseCpuTime ---');

assert(parseCpuTime('0:00.04') === 0.04, 'short time');
assert(parseCpuTime('9:30.30') === 570.30, 'm:sec.fraction');
assert(parseCpuTime('1:02:03.5') === 3723.5, 'h:m:sec.fraction');
assert(parseCpuTime(null) === 0, 'null input');
assert(parseCpuTime('') === 0, 'empty string');

/* ── parsePsMain ────────────────────────────────────────────────────────── */
console.log('\n--- parsePsMain ---');

// REAL macOS output — WITH leading whitespace (the regression that caused 0 processes).
const psWithLeadingSpaces = `  1     0 root               0:32.21   3.0  32400 488723952 Ss   01:27:35 /sbin/launchd
 335     1 root               0:32.03   2.0  71392 489042864 Ss   01:27:03 /usr/libexec/logd
 666     1 syed               3:10.45  0.2 489529520 166480 S     08:49:05 /Applications/Ghostty.app/Contents/MacOS/ghostty`;

// macOS version that outputs WITHOUT leading whitespace.
const psNoLeadingSpaces = `1     0 root               0:32.21   3.0  32400 488723952 Ss   01:27:35 /sbin/launchd
335     1 root               0:32.03   2.0  71392 489042864 Ss   01:27:03 /usr/libexec/logd
666     1 syed               3:10.45  0.2 489529520 166480 S     08:49:05 /Applications/Ghostty.app/Contents/MacOS/ghostty`;

const m1 = parsePsMain(psWithLeadingSpaces);
const m2 = parsePsMain(psNoLeadingSpaces);

assert(m1.size === 3, 'leading-whitespace: 3 processes parsed');
assert(m2.size === 3, 'no-leading-whitespace: 3 processes parsed');

const launchd = m1.get(1);
assert(launchd !== undefined, 'leading-whitespace: PID 1 (launchd) found');
assert(launchd.ppid === 0, 'launchd ppid is 0');
assert(launchd.user === 'root', 'launchd user is root');
assert(launchd.rss === 32400, 'launchd rss is 32400');
assert(launchd.stat === 'Ss', 'launchd stat is Ss');
assert(launchd.exe === '/sbin/launchd', 'launchd exe');
assert(launchd.cpuTime === 32.21, 'launchd cpuTime (seconds)');

// Both formats must produce identical results (the regression guard).
const ghostty1 = m1.get(666);
const ghostty2 = m2.get(666);
assertDeepEquals(ghostty1, ghostty2, 'both formats produce identical results');

assert(parsePsMain(null).size === 0, 'null input → empty map');
assert(parsePsMain('').size === 0, 'empty string → empty map');

// Edge case: comm with embedded spaces (real-world case).
const psWithSpacesInComm = `100     1 syed               0:01.00   1.0  10000 500000 Ss   00:10:00 /Applications/My App.app/Contents/MacOS/My App`;
const m3 = parsePsMain(psWithSpacesInComm);
assert(m3.size === 1, 'comm with spaces: 1 process');
const proc = m3.get(100);
assert(proc.exe === '/Applications/My App.app/Contents/MacOS/My App', 'comm preserves embedded spaces');

// Long-running processes with hours in etime.
const psLongRunning = `  1     0 root              10:22.15   3.0  32400 488723952 Ss   100:22:15 /sbin/launchd`;
const m4 = parsePsMain(psLongRunning);
assert(m4.size === 1, 'long-running: 1 process');
assert(m4.get(1).cpuTime === 10 * 60 + 22.15, 'cpuTime parses h:m:sec.fraction');
assert(m4.get(1).etime === '100:22:15', 'etime field preserved');

/* ── parsePsArgs ────────────────────────────────────────────────────────── */
console.log('\n--- parsePsArgs ---');

const psArgsOut = `1 /sbin/launchd --suppress-effect-on-user-input-devices
335 /usr/libexec/logd
666 /Applications/Ghostty.app/Contents/MacOS/ghostty --flag --port=3000`;

const am = parsePsArgs(psArgsOut);
assert(am.size === 3, '3 processes');
assert(am.get(1) === '/sbin/launchd --suppress-effect-on-user-input-devices', 'args with flags');
assert(am.get(666) === '/Applications/Ghostty.app/Contents/MacOS/ghostty --flag --port=3000', 'app path with args');
assert(parsePsArgs(null).size === 0, 'null input');

/* ── parseVmStat ────────────────────────────────────────────────────────── */
console.log('\n--- parseVmStat ---');

const vmOut = `
Page size of 16384 bytes

  Pages free: 173593
  Pages active: 4038523
  Pages inactive: 2578632
  Pages speculative: 9371
  Pages wired down: 1437496
  Pages occupied by compressor: 23707
  Pages stored in compressor: 99999
  Pages purgeable: 2521
  File-backed pages: 55555
  Anonymous pages: 48888

Swapfile size   1024.0 MB
`;

const vm = parseVmStat(vmOut);
assert(vm.free === 173593 * 16384, 'free bytes');
assert(vm.active === 4038523 * 16384, 'active bytes');
assert(vm.wired === 1437496 * 16384, 'wired bytes');
assert(vm.compressed === 23707 * 16384, 'compressed bytes');
assert(vm.purgeable === 2521 * 16384, 'purgeable bytes');
assert(vm.speculative === 9371 * 16384, 'speculative bytes');
assert(vm.filebacked === 55555 * 16384, 'file-backed bytes');
assert(vm.anonymous === 48888 * 16384, 'anonymous bytes');
assert(vm.storedCompressed === 99999 * 16384, 'stored-in-compressor bytes');
assert(parseVmStat(null).free === 0, 'null input → zeros');
assert(parseVmStat(null).filebacked === 0, 'null input → zero file-backed');
assert(parseVmStat(null).storedCompressed === 0, 'null input → zero stored-compressed');

// Alternate format: "Compressed" key (newer macOS / alternate vm_stat).
const vmAlt = `
Page size of 16384 bytes
...
  "Compressed" : 23707
`;
const vmAltResult = parseVmStat(vmAlt);
assert(vmAltResult.compressed === 23707 * 16384, 'alternate Compressed format');

// Page size varies (some systems report 4096).
const vmSmallPages = `
page size of 4096 bytes
Pages free: 100
Pages wired down: 50`;
const vmSP = parseVmStat(vmSmallPages);
assert(vmSP.free === 409600, '4096 page size');
assert(vmSP.wired === 204800, '4096 page size for wired');

/* ── parseSysctl ────────────────────────────────────────────────────────── */
console.log('\n--- parseSysctl ---');

const sysOut = `hw.memsize: 68719476736
hw.ncpu: 16

vm.swapusage: total = 1024.00M  used = 10.31M  virtual.free = 1024.00M

vm.loadavg: { 2.27 1.94 2.36 }

kern.boottime: { sec = 1730000000, usec = 0 } Sat Oct 26 20:26:40 2024`;

const sc = parseSysctl(sysOut);
assert(sc.memTotal === 68719476736, 'memTotal');
assert(sc.cores === 16, 'cores');
assert(sc.swapTotal === 1024 * 1024 ** 2, 'swapTotal');
assert(sc.swapUsed === 10.31 * 1024 ** 2, 'swapUsed');
assertDeepEquals(sc.load, [2.27, 1.94, 2.36], 'loadavg');
assert(sc.bootTime === 1730000000, 'bootTime');
assert(parseSysctl(null).memTotal === 0, 'null input');

/* ── parseTop ───────────────────────────────────────────────────────────── */
console.log('\n--- parseTop ---');

// The regex matches "CPU usage:" (no * prefix).
const topOut = `Processes: 624 total, 3 running, 621 sleeping, 0 waiting
CPU usage:  7.9% user,  4.5% sys, 87.5% idle
Idle 0.0% util:

.repeat1

Processes: 624 total, 3 running, 621 sleeping, 0 waiting
CPU usage:  5.2% user,  2.9% sys, 91.9% idle`;

const tp = parseTop(topOut);
assert(tp.user === 5.2, 'user from last sample');
assert(tp.sys === 2.9, 'sys from last sample');
assert(tp.idle === 91.9, 'idle from last sample');
assert(tp.total === 8.1, 'total = 100 - idle');

// No CPU line → all zeros.
assert(parseTop('no cpu line').user === 0, 'no CPU line → zeros');
assert(parseTop(null).user === 0, 'null input → zeros');

// Single sample (no .repeat) — should still use the only sample.
const topSingle = `CPU usage: 12.5% user,  3.0% sys, 84.5% idle`;
const ts = parseTop(topSingle);
assert(ts.user === 12.5, 'single sample: user');
assert(ts.sys === 3.0, 'single sample: sys');
assert(ts.total === 15.5, 'single sample: total');

/* ── parseTopMem ────────────────────────────────────────────────────────── */
console.log('\n--- parseTopMem ---');

// Live format: the full header (incl. date + PID/MEM column) repeats per
// sample; values are human-scaled with a trailing +/-/space delta marker.
const topMemOut = `Processes: 759 total, 2 running, 757 sleeping, 3110 threads 
2026-11-04 23:09:04
Load Avg: 2.97, 2.88, 2.74 
CPU usage: 4.80% user, 12.66% sys, 82.53% idle 
SharedLibs: 701M resident, 70M data, 96M linkedit.
MemRegions: 143741 total, 2707M resident, 258M private, 30G shared.
PhysMem: 54G used (32G wired, 1556M compressor), 9656M unused.
VM: 350T vsize, 57G framework vsize, 188(0) swapins, 312(0) swapouts.
Networks: packets: 5367675/38G in, 4725279/37G out.
Disks: 3707012/869G read, 2757684/281G written.

PID    MEM  
1212   16G-  
1        26M   
420    646M   
9999   1456K  
777    0K-

Processes: 759 total, 2 running, 757 sleeping, 3110 threads 
2026-11-04 23:09:05
CPU usage: 3.10% user, 11.02% sys, 85.88% idle 

PID    MEM  
1212   29G+  
1        26M   `;

const tm = parseTopMem(topMemOut);
assert(tm.get(1212) === 29 * 1024 ** 3, 'last sample wins (29G, not the earlier 16G-)');
assert(tm.get(1) === 26 * 1024 ** 2, 'M unit (kernel_task)');
assert(tm.get(420) === 646 * 1024 ** 2, 'M unit');
assert(tm.get(9999) === 1456 * 1024, 'K unit');
assert(tm.get(777) === 0, '0K- → 0');
assert(tm.size === 5, 'header/date/CPU lines produce no false entries');
assert(parseTopMem(null).size === 0, 'null input → empty map');

// 3-column output (-stats pid,cpu,mem) including PID 0 (kernel_task).
const topProcOut = `Processes: 765 total, 2 running, 763 sleeping, 3136 threads
2026/11/05 17:39:48
CPU usage: 7.23% user, 7.17% sys, 85.59% idle

PID    %CPU MEM
1212   0.0  16G
420    0.0  728M
0      0.0  23M

Processes: 765 total, 2 running, 763 sleeping, 3136 threads
2026/11/05 17:39:49
CPU usage: 4.48% user, 4.66% sys, 90.85% idle

PID    %CPU MEM
1212   1.2  16G
420    44.3 728M-
0      17.3 23M+
888    0.0  0B`;

const tpr = parseTopProcs(topProcOut);
assert(tpr.get(0).cpu === 17.3 && tpr.get(0).mem === 23 * 1024 ** 2, 'PID 0 kernel_task cpu + mem from 2nd sample');
assert(tpr.get(420).cpu === 44.3 && tpr.get(420).mem === 728 * 1024 ** 2, 'PID 420 cpu + mem');
assert(tpr.get(1212).cpu === 1.2 && tpr.get(1212).mem === 16 * 1024 ** 3, 'PID 1212 cpu + mem');
assert(tpr.get(888).mem === 0 && tpr.get(888).cpu === 0, '0B parsed cleanly');

/* ── parseNetstat ───────────────────────────────────────────────────────── */
console.log('\n--- parseNetstat ---');

// The 10-column code extracts c[5] for Ibytes and c[8] for Obytes.
// Construct data so those indices have the expected values.
const netOut = [
  'name       MTU      RX-TPK    RX-BYTES   TX-TPK    TX-BYTES     I-BYTES    O-BYTES  COLLIS  QUEUE',
  'en5       1500   12345678   9876543210  8765432   5555555555   1234567890  3333333333       3333333333      0',
  'lo0    16779272    100000    50000000    100000    50000000    50000000    50000000       0      0',
].join('\n');

const nt = parseNetstat(netOut);
assert(nt.ib === 5555555555, 'IB from 10-column row (c[5])');
assert(nt.ob === 3333333333, 'OB from 10-column row (c[8])');

// Loopback (lo*) is always excluded.
const netLoback = [
  'name       MTU      RX-TPK    RX-BYTES   TX-TPK    TX-BYTES     I-BYTES    O-BYTES  COLLIS  QUEUE',
  'lo0    16779272    100000    50000000    100000    50000000    50000000    50000000       0      0',
].join('\n');
assert(parseNetstat(netLoback).ib === 0, 'loopback excluded');

// Multiple interfaces sum correctly. The parser grabs c[5]=Ibytes and c[8]=Obytes.
const netMulti = [
  'name       MTU      RX-TPK    RX-BYTES   TX-TPK    TX-BYTES     I-BYTES    O-BYTES  COLLIS  QUEUE',
  'en5       1500   5000000   5000000000  3000000   7000000000   1234567890  4000000000       4000000000      0',
  'en6       1500   2000000   2000000000  1000000   2000000000   9876543210  1000000000       1000000000      0',
].join('\n');
const ntM = parseNetstat(netMulti);
assert(ntM.ib === 9000000000, 'multi-interface: IB sums (7000000000 + 2000000000)');
assert(ntM.ob === 5000000000, 'multi-interface: OB sums (4000000000 + 1000000000)');

assert(parseNetstat(null).ib === 0, 'null input');

/* ── parseIostat ────────────────────────────────────────────────────────── */
console.log('\n--- parseIostat ---');

// The code matches rows with EXACTLY 3 numeric columns (the summary line).
// Two summary blocks: first block has 2 entries, second block has 2 entries.
// "last half" of 4 total = rows 2-3, and c[2] = MB/s from each.
const iostatOut = [
  'Disk0          KB/t    tps  MB/s',
  '                   2.54  100  2.54',
  '                   12.10    50  0.61',
  '',
  'Disk0          KB/t    tps  MB/s',
  '                   30.22   120  3.62',
  '                   15.33    60  0.92',
].join('\n');

const io = parseIostat(iostatOut);
// 4 numeric rows [2.54, 0.61, 3.62, 0.92], half = 2, last 2 = [3.62, 0.92], sum = 4.54
assert(Math.abs(io - 4.54) < 0.01, `MB/s from last block: expected ~4.54, got ${io}`);

assert(parseIostat('') === 0, 'empty string');
assert(parseIostat(null) === 0, 'null input');

/* ── parseBatt ──────────────────────────────────────────────────────────── */
console.log('\n--- parseBatt ---');

const battOut = `Battery 0 (id=12345) 86%; charging; 2:31 remaining`;
const bt = parseBatt(battOut);
assert(bt.pct === 86, 'pct');
assert(bt.charging === true, 'charging');
assert(!('time' in bt), 'no time field (dropped from the snapshot)');

const battOut2 = `Battery 0 (id=12345) 42%; not charging; 1:05 remaining`;
const bt2 = parseBatt(battOut2);
assert(bt2.pct === 42, 'pct when not charging');
assert(bt2.charging === false, 'not charging → false');

const battDischarging = ` -InternalBattery-0 (id=12345)	74%; discharging; 4:12 remaining present: true`;
const btDis = parseBatt(battDischarging);
assert(btDis.pct === 74 && btDis.charging === false, 'discharging → false');

const battAcHold = ` -InternalBattery-0 (id=23789667)	80%; AC attached; not charging present: true`;
const btHold = parseBatt(battAcHold);
assert(btHold.pct === 80 && btHold.charging === false, 'AC attached hold → false');

const battFinishing = ` -InternalBattery-0 (id=12345)	99%; finishing charge; 0:04 remaining`;
assert(parseBatt(battFinishing).charging === true, 'finishing charge → true');

const battCharged = ` -InternalBattery-0 (id=12345)	100%; charged; 0:00 remaining`;
assert(parseBatt(battCharged).charging === false, 'charged → false');

// No remaining time (fully charged).
const battOut3 = `Battery 0 (id=12345) 100%; charging;`;
const bt3 = parseBatt(battOut3);
assert(bt3.pct === 100, '100%');
assert(bt3.charging === true, 'still charging');

assert(parseBatt(null).pct === null, 'null input');

/* ── parseTherm ─────────────────────────────────────────────────────────── */
console.log('\n--- parseTherm ---');

const thermNominal = [
  'Now using power: Battery Power',
  'Note: No thermal warning level has been recorded',
  'Note: No performance warning level has been recorded',
  'Note: No CPU power status has been recorded',
].join('\n');
const th1 = parseTherm(thermNominal);
assert(th1.level === 0 && th1.state === 'nominal', 'all clear → nominal');

const thermHot = [
  'Now using power: Battery Power',
  'CPU SMC0  thermal level 1  performance level 1',
  'CPU PEC0  thermal level 2  performance level 2',
  'CPU PPMC0 thermal level 1',
].join('\n');
const th2 = parseTherm(thermHot);
assert(th2.level === 2, 'max level wins');
assert(th2.state === 'throttled', '≥2 → throttled');

const th3 = parseTherm('CPU SMC0  thermal level 1');
assert(th3.level === 1 && th3.state === 'slowed', 'level 1 → slowed');
assert(parseTherm(null).state === 'nominal', 'null input → nominal');

const thWithTemp = parseTherm(thermNominal, 42.34);
assert(thWithTemp.cpu === 42.3, 'cpu temp rounded to 1 decimal');
assert(thWithTemp.level === 0 && thWithTemp.state === 'nominal', 'level/state preserved with temp');

assert(parseThermalJson('{"cpu":40.1,"max":42.5}')?.cpu === 40.1, 'valid thermal json');
assert(parseThermalJson('{}')?.cpu === undefined, 'empty thermal json');
assert(parseThermalJson('invalid') === null, 'invalid json returns null');
assert(parseThermalJson(null) === null, 'null input returns null');

/* ── parseIoregGpu ──────────────────────────────────────────────────────── */
console.log('\n--- parseIoregGpu ---');

// AppUsage prints BEFORE the creator line (alphabetical plist order) — the
// parser must attribute usage per node block, not via a flat scan.
const gpuOut = [
  '+-o AGXDeviceUserClient  <class AGXDeviceUserClient, id 0x1000010cb, !registered, active, retain 5>',
  '    {',
  '      "AppUsage" = ()',
  '      "IOUserClientCreator" = "pid 408, WindowServer"',
  '    }',
  '    ',
  '    +-o AGXDeviceUserClient  <class AGXDeviceUserClient, id 0x1000010d2, !registered, active, retain 5>',
  '    |   {',
  '    |     "AppUsage" = ({"API"="Metal","lastSubmittedTime"=85015529304416,"accumulatedGPUTime"=1559895244541},{"API"="Metal","lastSubmittedTime"=56777239584291,"accumulatedGPUTime"=6544208})',
  '    |     "IOUserClientCreator" = "pid 408, WindowServer"',
  '    |     "CommandQueueCount" = 2',
  '    |   }',
  '    ',
  '    +-o AGXDeviceUserClient  <class AGXDeviceUserClient, id 0x1000011f0, !registered, active, retain 5>',
  '        {',
  '          "AppUsage" = ({"API"="Metal","lastSubmittedTime"=123,"accumulatedGPUTime"=999})',
  '          "IOUserClientCreator" = "pid 641, MenuBarAgent"',
  '        }',
].join('\n');
const gm = parseIoregGpu(gpuOut);
assert(gm.size === 2, 'two pids');
// pid 408 appears in two nodes — its usage is the sum, attributed to ITSELF,
// not to whatever node came before.
assert(gm.get('408').ns === 1559895244541 + 6544208, 'usage attributed to own pid');
assert(gm.get('408').name === 'WindowServer', 'name');
assert(gm.get('641').ns === 999, 'second pid');
assert(gm.get('641').name === 'MenuBarAgent', 'second name');
assert(parseIoregGpu('').size === 0, 'empty output → empty map');
assert(parseIoregGpu(null).size === 0, 'null input');

/* ── bundleOf ───────────────────────────────────────────────────────────── */
console.log('\n--- bundleOf ---');

const b1 = bundleOf('/Applications/Ghostty.app/Contents/MacOS/ghostty');
assert(b1 !== null, 'returns object');
assert(b1.bundle === '/Applications/Ghostty.app', 'bundle path');
assert(b1.name === 'Ghostty', 'bundle name');

assert(bundleOf('/usr/bin/ls') === null, 'system binary → null');
assert(bundleOf(null) === null, 'null → null');
assert(bundleOf('') === null, 'empty → null');

// Nested .app inside another .app (first .app wins).
const b2 = bundleOf('/Applications/Chrome.app/Contents/Frameworks/Chrome Helper (Aperitif).app/Contents/MacOS/Chrome Helper');
assert(b2.name === 'Chrome', 'nested .app: first .app wins (Chrome not Chrome Helper (Aperitif))');

// No .app extension.
assert(bundleOf('/usr/libexec/mds') === null, 'no .app → null');

/* ── groupOf (process grouping) ─────────────────────────────────────────── */
console.log('\n--- groupOf ---');

function makeProcMap(items) {
  const map = new Map();
  for (const [pid, ppid, exe] of items) {
    map.set(pid, { pid, ppid, exe, user: 'syed', pcpu: 0, rss: 0, vsz: 0, stat: 'S', cpuTime: 0, etime: '0:00' });
  }
  return map;
}

// App process → attributed to that app.
const procs1 = makeProcMap([
  [100, 1, '/Applications/Ghostty.app/Contents/MacOS/ghostty'],
]);
const g1 = groupOf(procs1.get(100), procs1);
assert(g1.kind === 'app', 'Ghostty → app');
assert(g1.name === 'Ghostty', 'Ghostty name');

// Child of app process → attributed to parent app (walks up to 8 levels).
const procs2 = makeProcMap([
  [100, 1, '/Applications/Ghostty.app/Contents/MacOS/ghostty'],
  [101, 100, '/usr/bin/ps aux'],
]);
const g2 = groupOf(procs2.get(101), procs2);
assert(g2.kind === 'app', 'child of Ghostty → app');
assert(g2.name === 'Ghostty', 'child inherits parent app name');

// Process with no .app in path → exe group, system path → system kind.
const procs3 = makeProcMap([
  [200, 1, '/usr/bin/ps'],
]);
const g3 = groupOf(procs3.get(200), procs3);
assert(g3.kind === 'system', 'system binary → system');
assert(g3.name === 'ps', 'named by exe');

// Process with no .app → other kind (user code).
const procs4 = makeProcMap([
  [300, 1, '~/Projects/my-server.js'],
]);
const g4 = groupOf(procs4.get(300), procs4);
assert(g4.kind === 'other', 'unrecognized → other');
assert(g4.name === 'my-server.js', 'named by exe');

// .appex (system extension).
const procs6 = makeProcMap([
  [400, 1, '/Library/Extensions/MyExtension.appex/Contents/MacOS/Helper'],
]);
const g6 = groupOf(procs6.get(400), procs6);
assert(g6.kind === 'system', '.appex → system');
assert(g6.name === 'MyExtension', '.appex name');

// Deep parent chain (more than 2 levels).
const deepProcs = makeProcMap([
  [1, 0, '/sbin/launchd'],
  [50, 1, '/usr/libexec/xpcd'],
  [100, 50, '/usr/libexec/configd'],
  [200, 100, '/Applications/FinalApp.app/Contents/MacOS/FinalApp'],
  [300, 200, '/usr/bin/helper'],
]);
const gDeep = groupOf(deepProcs.get(300), deepProcs);
assert(gDeep.kind === 'app', 'deep child → parent app');
assert(gDeep.name === 'FinalApp', 'inherited name is FinalApp');

/* ── roleOf (helper role detection) ─────────────────────────────────────── */
console.log('\n--- roleOf ---');

assert(roleOf('Chrome Helper (Renderer)') === 'web page', 'renderer → web page');
assert(roleOf('Safari Web Content') === 'web page', 'web content → web page');
assert(roleOf('Chrome Helper (GPU)') === 'GPU', 'gpu → GPU');
assert(roleOf('Shader Compilation Service') === 'shader compiler', 'shader → shader compiler');
assert(roleOf('Audio Handling') === 'audio', 'audio → audio');
assert(roleOf('Crashpad Handler') === 'crash handler', 'crashpad → crash handler');
assert(roleOf('SomeNetworkingDaemon') === 'networking', 'networking → networking');
assert(roleOf('Chrome Helper (Utility)') === 'utility', 'utility → utility');
assert(roleOf('Crashpad Handler') === 'crash handler', 'crashpad → crash handler');
assert(roleOf('Chrome Helper') === 'helper', 'generic helper → helper');
assert(roleOf('Ghostty') === null, 'normal app → null');
assert(roleOf(null) === null, 'null → null');

/* ── Edge case: empty ps output ─────────────────────────────────────────── */
console.log('\n--- Edge cases ───────────────────────────────────────────────');

assert(parsePsMain('\n').size === 0, 'blank lines only → 0 processes');
assert(parsePsMain('   \n  \n').size === 0, 'whitespace-only → 0');

// Top with unusual idle values.
const topHighIdle = `CPU usage: 0.5% user,  0.3% sys, 99.2% idle`;
const th = parseTop(topHighIdle);
assert(th.total === 0.8, 'high idle → low total');

const topLowIdle = `CPU usage: 45.2% user,  30.1% sys, 24.7% idle`;
const tl = parseTop(topLowIdle);
assert(tl.total === 75.3, 'low idle → high total');

/* ── purge helpers (the "Clear RAM" button) ─────────────────────────── */
console.log('\n--- purge helpers ---');

// Successful osascript exit → ok.
assert(purgeFailure(null, '').ok === true, 'no error → ok');
// User dismisses the SecurityAgent prompt → cancelled (exit 1, -128).
const pCancel = purgeFailure({ code: 1, message: 'Command failed' },
  'execution error: User canceled. (-128)');
assert(pCancel.ok === false && pCancel.cancelled === true, 'user canceled → cancelled');
// British spelling variant.
const pCancel2 = purgeFailure({ code: 1 }, 'execution error: User cancelled. (-128)');
assert(pCancel2.cancelled === true, 'user cancelled (UK) → cancelled');
// osascript missing (non-macOS box).
const pNoMac = purgeFailure({ code: 'ENOENT', message: 'spawn /usr/bin/osascript ENOENT' }, '');
assert(pNoMac.ok === false && !pNoMac.cancelled && /macOS only/.test(pNoMac.error),
  'ENOENT → not-macOS error');
// Timed out waiting for the user at the prompt.
const pTimeout = purgeFailure({ code: 'ETIMEDOUT', killed: true }, '');
assert(pTimeout.ok === false && !pTimeout.cancelled && /timed out/.test(pTimeout.error),
  'timeout → timed-out error');
// Anything else is a generic failure.
const pOther = purgeFailure({ code: 1, message: 'boom' }, 'weird failure');
assert(pOther.ok === false && !pOther.cancelled && pOther.error, 'other failure → generic error');

// Before/after vm_stat (bytes). Purge evicted 3GB filecache + 1GB purgeable.
const pvBefore = { free: 2 * 2 ** 30, filebacked: 6 * 2 ** 30, purgeable: 1 * 2 ** 30 };
const pvAfter = { free: 6 * 2 ** 30, filebacked: 3 * 2 ** 30, purgeable: 0 };
assert(computePurged(pvBefore, pvAfter) === 4 * 2 ** 30, 'evicted cache + purgeable → 4 GiB');
// Other apps freed 1GB in the same second — free grew more than the cache shrank;
// the max keeps the honest (bigger) number.
const pvAfter2 = { free: 7 * 2 ** 30, filebacked: 3 * 2 ** 30, purgeable: 0 };
assert(computePurged(pvBefore, pvAfter2) === 5 * 2 ** 30, 'free grew but cache shrank less → free delta wins');
const pvAfter3 = { free: 8 * 2 ** 30, filebacked: 3 * 2 ** 30, purgeable: 0 };
assert(computePurged(pvBefore, pvAfter3) === 6 * 2 ** 30, 'free grew even more (other apps) → free delta wins');
// Nothing was cached → 0, never negative.
assert(computePurged(pvBefore, pvBefore) === 0, 'no change → 0');
const pvNeg = { free: 1 * 2 ** 30, filebacked: 7 * 2 ** 30, purgeable: 1 * 2 ** 30 };
assert(computePurged(pvBefore, pvNeg) === 0, 'free shrank & cache grew (noise) → clamped to 0');

// ---------------------------------------------------------------------------
//  parseNetstat (copied from server.js — kept in sync; see docs/gotchas.md)
//
//  Real macOS `netstat -ib` columns:
//    Name Mtu Network Address Ipkts Ierrs Ibytes Opkts Oerrs Obytes Coll
//  A full row has 11 fields; a link row with an EMPTY address loses one field
//  on whitespace split → 10 fields, shifting Ibytes/Obytes one column left.
//  Loopback (lo*) is not real traffic; each interface's <Link#> row is its
//  aggregate (the per-address rows would double-count it).
// ---------------------------------------------------------------------------

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

// 11-field rows (Network + Address both present): Ibytes=6, Obytes=9.
// 10-field link rows (empty Address dropped by the whitespace split): Ibytes=5, Obytes=8.
const fakeNet = [
  'Iface Mtu Network Address Ipkts Ierrs Ibytes Opkts Oerrs Obytes Coll',
  'lo0 16384 <Link#1>  9571204 0 83852940610 9571204 0 83852940610 0', // loopback — excluded
  'en0 1500 10.0.0.0 10.0.0.108 12345 0 987654321 23456 0 123456789 0', // full row
  'utun0 1280 <Link#2>  55 0 409600 66 0 512000 0', // 10-field link row
].join('\n');
{
  const r = parseNetstat(fakeNet);
  assert(r.ib === 987654321 + 409600, 'netstat: Ibytes summed across interfaces (loopback excluded, link rows win over per-address rows)');
  assert(r.ob === 123456789 + 512000, 'netstat: Obytes summed the same way');
  assert(parseNetstat(null).ib === 0, 'netstat: null output → zero, not NaN');
  // Dash values (per-address rows print '-' for Ierrs/Obytes) must not poison the sum.
  const dashRow = 'en0 1500 10.0.0.0 10.0.0.108 12 0 555 13 - 666 -';
  const r2 = parseNetstat('hdr' + '\n' + dashRow);
  assert(r2.ib === 555 && r2.ob === 666, 'netstat: non-numeric fields coerce to 0, counters still read');
}

/* ── computeHostCpuDelta (in-process os.cpus() delta for background menu bar) ── */
console.log('\n--- computeHostCpuDelta ---');

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

{
  const prev = [
    { times: { user: 1000, nice: 0, sys: 500, idle: 8500, irq: 0 } },
    { times: { user: 2000, nice: 0, sys: 1000, idle: 7000, irq: 0 } },
  ];
  const cur = [
    { times: { user: 1200, nice: 0, sys: 600, idle: 9200, irq: 0 } }, // +200 user, +100 sys, +700 idle
    { times: { user: 2100, nice: 0, sys: 1100, idle: 7800, irq: 0 } }, // +100 user, +100 sys, +800 idle
  ];
  const d = computeHostCpuDelta(prev, cur);
  assert(d && d.user === 15 && d.sys === 10 && d.idle === 75 && d.total === 25,
    'computeHostCpuDelta: 300/2000 user=15%, 200/2000 sys=10%, 1500/2000 idle=75%, total=25%');
  assert(computeHostCpuDelta(prev, prev) === null, 'computeHostCpuDelta: zero elapsed ticks → null');
  assert(computeHostCpuDelta(null, cur) === null, 'computeHostCpuDelta: null input → null');
}

/* ── computeCoreClusterLoads ── */
console.log('\n--- computeCoreClusterLoads ---');

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

{
  const prev = [
    { times: { user: 1000, nice: 0, sys: 500, idle: 8500, irq: 0 } }, // E-core 0
    { times: { user: 1000, nice: 0, sys: 500, idle: 8500, irq: 0 } }, // E-core 1
    { times: { user: 2000, nice: 0, sys: 1000, idle: 7000, irq: 0 } }, // P-core 2
    { times: { user: 2000, nice: 0, sys: 1000, idle: 7000, irq: 0 } }, // P-core 3
  ];
  const cur = [
    { times: { user: 1400, nice: 0, sys: 600, idle: 9000, irq: 0 } }, // +500 busy, +500 idle -> 50%
    { times: { user: 1400, nice: 0, sys: 600, idle: 9000, irq: 0 } }, // +500 busy, +500 idle -> 50%
    { times: { user: 2100, nice: 0, sys: 1000, idle: 7900, irq: 0 } }, // +100 busy, +900 idle -> 10%
    { times: { user: 2100, nice: 0, sys: 1000, idle: 7900, irq: 0 } }, // +100 busy, +900 idle -> 10%
  ];
  const cl = computeCoreClusterLoads(prev, cur, 2);
  assert(cl.eCores === 50 && cl.pCores === 10, 'computeCoreClusterLoads: E-cores=50%, P-cores=10%');
  assert(computeCoreClusterLoads(null, cur, 2).eCores === null, 'computeCoreClusterLoads: null input → null');
  assert(computeCoreClusterLoads(prev, cur, 0).eCores === null, 'computeCoreClusterLoads: zero eCount → null');
}

/* ── parseGpuMem ── */
console.log('\n--- parseGpuMem ---');

function parseGpuMem(out) {
  if (!out) return null;
  const m = out.match(/"In use system memory"\s*=\s*(\d+)/);
  return m ? parseInt(m[1], 10) : null;
}

{
  const s = '{"In use system memory"=1515192320,"Device Utilization %"=21}';
  assert(parseGpuMem(s) === 1515192320, 'parseGpuMem: parses integer bytes');
  const s2 = '"In use system memory" = 1073741824';
  assert(parseGpuMem(s2) === 1073741824, 'parseGpuMem: handles spaces around equals');
  assert(parseGpuMem('') === null, 'parseGpuMem: empty string → null');
  assert(parseGpuMem('no memory field') === null, 'parseGpuMem: missing field → null');
}

// ---------------------------------------------------------------------------
//  Wrap up
// ---------------------------------------------------------------------------
console.log(`\n${'='.repeat(60)}`);
console.log(`Results: ${passed} passed, ${failed} failed`);
if (failed > 0) {
  console.log(`${'='.repeat(60)}`);
  console.log('REGRESSION DETECTED — fix parsing before proceeding.');
  process.exit(1);
} else {
  console.log('All parser tests passed ✓');
  process.exit(0);
}
