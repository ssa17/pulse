#!/usr/bin/env node
/**
 * server.integration.test.js — boots the REAL server in a throwaway HOME and
 * checks the cross-component contracts that unit tests can't see:
 *
 *   - /api/status carries the menu layout (menuRows/barRows) + layoutGen
 *   - a settings write (the web-fallback path) advances layoutGen in the file
 *     AND in /api/status, and the new layout shows up
 *   - the status `net` (MB/s) and the snapshot `sys.net` (bytes/s) are the same
 *     measurement at the same scale (catches unit mix-ups: a bytes/s value
 *     mislabeled as MB/s renders as a thousand-fold-wrong figure)
 *   - an empty layout is a valid layout (all rows off)
 *
 * Run:  node server.integration.test.js        (~15s, needs a mac — it samples)
 */
'use strict';

const { spawn } = require('child_process');
const fs = require('fs');
const os = require('os');
const path = require('path');
const http = require('http');

let passed = 0, failed = 0;
function assert(cond, msg) {
  if (!cond) { failed++; console.error(`  FAIL: ${msg}`); return; }
  passed++;
  console.log(`  ok: ${msg}`);
}

const PORT = 18791 + Math.floor(Math.random() * 1000);
const fakeHome = fs.mkdtempSync(path.join(os.tmpdir(), 'pulse-it-'));
const MENU_IDS = ['cpu', 'gpu', 'memory', 'thermal', 'network', 'uptime'];
const BAR_IDS = ['cpu', 'gpu', 'memory', 'network'];
const activeChildren = new Set();

function getOnPort(port, p) {
  return new Promise((res, rej) => {
    http.get({ host: '127.0.0.1', port, path: p }, (r) => {
      let b = '';
      r.on('data', (c) => (b += c));
      r.on('end', () => res({ code: r.statusCode, json: () => JSON.parse(b) }));
    }).on('error', rej);
  });
}
function postOnPort(port, p, body) {
  return new Promise((res, rej) => {
    const req = http.request({ host: '127.0.0.1', port, path: p, method: 'POST',
      headers: { 'Content-Type': 'application/json' } }, (r) => {
      let b = '';
      r.on('data', (c) => (b += c));
      r.on('end', () => res({ code: r.statusCode, json: () => JSON.parse(b) }));
    });
    req.on('error', rej);
    req.end(JSON.stringify(body));
  });
}
const get = (p) => getOnPort(PORT, p);
const post = (p, body) => postOnPort(PORT, p, body);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function spawnManagedServer(extraEnv = {}) {
  return new Promise((resolve, reject) => {
    const proc = spawn(process.execPath, [path.join(__dirname, 'server.js')], {
      env: { ...process.env, PORT: '0', ...extraEnv },
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    activeChildren.add(proc);
    proc.on('exit', () => activeChildren.delete(proc));
    let buf = '';
    let settled = false;
    const timer = setTimeout(() => {
      if (!settled) { settled = true; reject(new Error('timed out waiting for PULSE_LISTENING')); }
    }, 10000);
    proc.stdout.on('data', (chunk) => {
      buf += chunk.toString();
      const m = buf.match(/PULSE_LISTENING=(\d+)/);
      if (m && !settled) {
        settled = true;
        clearTimeout(timer);
        resolve({ proc, port: +m[1] });
      }
    });
    proc.on('exit', (code) => {
      if (!settled) {
        settled = true;
        clearTimeout(timer);
        reject(new Error(`server exited early with code ${code}`));
      }
    });
  });
}

function waitForExit(proc, timeoutMs = 4000) {
  if (proc.exitCode !== null || proc.signalCode !== null) return Promise.resolve();
  return new Promise((resolve) => {
    const t = setTimeout(() => {
      try { proc.kill('SIGKILL'); } catch {}
      resolve();
    }, timeoutMs);
    proc.once('exit', () => { clearTimeout(t); resolve(); });
  });
}

async function stopProc(proc, sig = 'SIGTERM') {
  if (!proc || proc.exitCode !== null || proc.signalCode !== null) return;
  try { proc.kill(sig); } catch {}
  await waitForExit(proc);
}

async function main() {
  const child = spawn(process.execPath, [path.join(__dirname, 'server.js')], {
    env: { ...process.env, HOME: fakeHome, PORT: String(PORT) },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  activeChildren.add(child);
  child.on('exit', (c) => {
    activeChildren.delete(child);
    if (!done) { failed++; console.error(`  FAIL: server exited early (code ${c})`); finish(); }
  });
  let done = false;

  // Wait for the backend to listen.
  let listening = null;
  const t0 = Date.now();
  while (Date.now() - t0 < 15000) {
    await sleep(250);
    try { const r = await get('/api/status'); if (r.code === 200) { listening = r.json(); break; } } catch {}
  }
  if (!listening) { failed++; console.error('  FAIL: server never answered /api/status'); finish(); return; }

  // Wait for the first real sample (cpu present) so status is fully populated.
  let st = null;
  while (Date.now() - t0 < 25000) {
    st = (await get('/api/status')).json();
    if (st.cpu && st.cpu.total != null && st.t > 0) break;
    await sleep(500);
  }

  console.log('status shape:');
  for (const k of ['cpu', 'memPct', 'memUsed', 'memTotal', 'gpuPct', 'thermal', 'net', 'bootTime', 'menuRows', 'barRows', 'layoutGen']) {
    assert(st[k] !== undefined, `status has \`${k}\``);
  }
  assert(Array.isArray(st.menuRows) && st.menuRows.every((id) => MENU_IDS.includes(id)), 'status menuRows ⊆ canonical ids');
  assert(Array.isArray(st.barRows) && st.barRows.every((id) => BAR_IDS.includes(id)), 'status barRows ⊆ bar-capable ids');
  assert(st.menuRows.join(',') === 'cpu,gpu,memory,network,uptime', `default menuRows (thermal off): got ${JSON.stringify(st.menuRows)}`);
  assert(st.barRows.join(',') === 'cpu,gpu,memory,network', `default barRows: got ${JSON.stringify(st.barRows)}`);
  assert(typeof st.layoutGen === 'number' && st.layoutGen >= 0, `layoutGen present (${st.layoutGen})`);
  assert(st.net && typeof st.net.down === 'number' && typeof st.net.up === 'number', 'status net is numeric down/up');

  // Unit consistency: status claims MB/s, the snapshot carries the same
  // measurement in bytes/s — the two must agree at their respective scales.
  // (Tolerance absorbs the toFixed(3) rounding of tiny rates.)
  const snap = (await get('/api/snapshot')).json();
  const sd = st.net.down * 1e6, su = st.net.up * 1e6;
  const nd = snap.sys.net.down, nu = snap.sys.net.up;
  assert(Math.abs(sd - nd) <= Math.max(64, Math.abs(nd) * 0.15),
    `status MB/s ↔ snapshot bytes/s agree for down (${sd.toFixed(1)} vs ${nd.toFixed(1)})`);
  assert(Math.abs(su - nu) <= Math.max(64, Math.abs(nu) * 0.15),
    `status MB/s ↔ snapshot bytes/s agree for up (${su.toFixed(1)} vs ${nu.toFixed(1)})`);

  console.log('settings round-trip + layoutGen:');
  const file = path.join(fakeHome, '.pulse', 'settings.json');
  const g0 = st.layoutGen;
  const p1 = (await post('/api/settings', { menuRows: ['cpu', 'memory'], barRows: ['cpu'] })).json();
  assert(p1.ok === true, 'POST settings accepted');
  const g1 = (await get('/api/settings')).json().layoutGen;
  assert(g1 === g0 + 1, `a settings write advances layoutGen (${g0} → ${g1})`);
  const onDisk = JSON.parse(fs.readFileSync(file, 'utf8'));
  assert(onDisk.layoutGen === g1, 'file carries the advanced layoutGen');
  assert(onDisk.menuRows.join(',') === 'cpu,memory' && onDisk.barRows.join(',') === 'cpu', 'file has the new layout');

  // The per-second settings read must publish the new layout in /api/status.
  let sawNewLayout = false;
  for (let i = 0; i < 8 && !sawNewLayout; i++) {
    await sleep(500);
    const s = (await get('/api/status')).json();
    sawNewLayout = s.menuRows.join(',') === 'cpu,memory' && s.barRows.join(',') === 'cpu' && s.layoutGen === g1;
  }
  assert(sawNewLayout, '/api/status reflects the settings file (menuRows/barRows/layoutGen)');

  // An EMPTY layout is a valid layout (all rows off — the app shows actions only).
  (await post('/api/settings', { menuRows: [], barRows: [] })).json();
  const g2 = (await get('/api/settings')).json();
  assert(g2.menuRows.length === 0 && g2.barRows.length === 0, 'empty layout is preserved, not "corrected" back to defaults');
  assert(g2.layoutGen === g1 + 1, 'the empty-layout write advanced layoutGen again');

  // Restore a usable layout before finishing (leaves the throwaway home anyway).
  (await post('/api/settings', { menuRows: ['cpu', 'gpu', 'memory', 'network', 'uptime'], barRows: ['cpu', 'gpu', 'memory', 'network'] })).json();

  console.log('blacklist multi-process sync + exit flush race:');
  {
    const blHome = path.join(fakeHome, 'bl-home');
    const blFile = path.join(blHome, '.pulse', 'blacklist.json');
    const targetExe = path.join(fakeHome, `pulse-bl-target-${process.pid}`);
    fs.mkdirSync(path.join(blHome, '.pulse'), { recursive: true });
    fs.symlinkSync('/bin/sleep', targetExe);

    const s1 = await spawnManagedServer({
      HOME: blHome,
      INTERVAL: '60000',
      PULSE_PORT_FILE: path.join(blHome, '.pulse', 'port-1'),
    });
    const s2 = await spawnManagedServer({
      HOME: blHome,
      INTERVAL: '250',
      PULSE_PORT_FILE: path.join(blHome, '.pulse', 'port-2'),
    });

    // Wait for both servers to finish their fast startup sample.
    for (const s of [s1, s2]) {
      const deadline = Date.now() + 10000;
      while (Date.now() < deadline) {
        try {
          const stProbe = (await getOnPort(s.port, '/api/status')).json();
          if (stProbe.t > 0) break;
        } catch {}
        await sleep(100);
      }
    }

    const added = (await postOnPort(s1.port, '/api/blacklist', {
      action: 'add',
      matchType: 'exe',
      pattern: targetExe,
      label: 'Test Sleep',
      sig: 'KILL',
    })).json();
    assert(added.ok === true && added.rules.length === 1 && added.summary.rev === 1,
      'server 1 adds rule and writes rev=1');
    const ruleId = added.rules[0].id;

    // Server 2 must observe the rule from disk automatically.
    let s2SawRule = false;
    for (let i = 0; i < 20 && !s2SawRule; i++) {
      const r = (await getOnPort(s2.port, '/api/blacklist')).json();
      if (r.rules.length === 1 && r.summary.rev === 1) s2SawRule = true;
      else await sleep(150);
    }
    assert(s2SawRule, 'server 2 observes newly added rule and rev=1 from disk');

    // Spawn a throwaway target process; server 2 (250ms loop) kills it and holds dirty pending stats.
    const dummy1 = spawn(targetExe, ['30'], { stdio: 'ignore' });
    activeChildren.add(dummy1);
    dummy1.on('exit', () => activeChildren.delete(dummy1));

    let s2Killed = false;
    for (let i = 0; i < 30 && !s2Killed; i++) {
      const r = (await getOnPort(s2.port, '/api/blacklist')).json();
      if (r.rules[0] && r.rules[0].kills >= 1) s2Killed = true;
      else await sleep(150);
    }
    assert(s2Killed, 'server 2 enforces rule and records in-memory pending kill stats');
    await waitForExit(dummy1, 2000);

    // Remove rule on server 1 BEFORE server 2 hits its 5s flush, then SIGTERM server 2.
    const removed = (await postOnPort(s1.port, '/api/blacklist', { action: 'remove', id: ruleId })).json();
    assert(removed.ok === true && removed.rules.length === 0 && removed.summary.rev === 2,
      'server 1 removes rule (rev=2)');

    await stopProc(s2.proc, 'SIGTERM');
    const afterRemoveDisk = JSON.parse(fs.readFileSync(blFile, 'utf8'));
    const s1AfterExit = (await getOnPort(s1.port, '/api/blacklist')).json();
    assert(afterRemoveDisk.rules.length === 0 && afterRemoveDisk.rev === 2,
      'server 2 exit flush does NOT resurrect removed rule on disk');
    assert(s1AfterExit.rules.length === 0, 'server 1 still sees empty blacklist after server 2 exit');

    // Also verify surviving rule state (pause on server 1) + dirty stats merge on server 2 exit.
    const s3 = await spawnManagedServer({
      HOME: blHome,
      INTERVAL: '250',
      PULSE_PORT_FILE: path.join(blHome, '.pulse', 'port-3'),
    });
    for (let i = 0; i < 40; i++) {
      try { if ((await getOnPort(s3.port, '/api/status')).json().t > 0) break; } catch {}
      await sleep(100);
    }
    const added2 = (await postOnPort(s1.port, '/api/blacklist', {
      action: 'add',
      matchType: 'exe',
      pattern: targetExe,
      label: 'Test Sleep',
      sig: 'KILL',
    })).json();
    const ruleId2 = added2.rules[0].id;
    const dummy2 = spawn(targetExe, ['30'], { stdio: 'ignore' });
    activeChildren.add(dummy2);
    dummy2.on('exit', () => activeChildren.delete(dummy2));
    let s3Killed = false;
    for (let i = 0; i < 30 && !s3Killed; i++) {
      const r = (await getOnPort(s3.port, '/api/blacklist')).json();
      if (r.rules[0] && r.rules[0].kills >= 1) s3Killed = true;
      else await sleep(150);
    }
    assert(s3Killed, 'server 3 kills target and holds pending kill stats');
    await waitForExit(dummy2, 2000);

    await postOnPort(s1.port, '/api/blacklist', { action: 'toggle', id: ruleId2, enabled: false });
    await stopProc(s3.proc, 'SIGTERM');
    const mergedDisk = JSON.parse(fs.readFileSync(blFile, 'utf8'));
    assert(mergedDisk.rules.length === 1 && mergedDisk.rules[0].enabled === false && mergedDisk.rules[0].kills >= 1,
      'server 3 exit flush merges kill count without reverting paused state from disk');

    await stopProc(s1.proc, 'SIGTERM');
  }

  console.log('port-file live probe, poisoned-pid healing, and owner protection:');
  {
    const pfHome = path.join(fakeHome, 'pf-home');
    const pfPath = path.join(pfHome, '.pulse', 'port-poisoned');
    fs.mkdirSync(path.dirname(pfPath), { recursive: true });
    // Seed a poisoned port file with an alive PID (this test runner) and dead port 1.
    fs.writeFileSync(pfPath, `1\n${process.pid}\n`);

    const p1 = await spawnManagedServer({ HOME: pfHome, PULSE_PORT_FILE: pfPath });
    const probe = (await getOnPort(p1.port, '/api/status?probe=1')).json();
    assert(probe.ok === true && probe.pid === p1.proc.pid && typeof probe.serverMtime === 'number' && probe.daemon === false,
      '/api/status?probe=1 responds immediately with pid, serverMtime, and daemon=false');

    let healed = false;
    for (let i = 0; i < 25 && !healed; i++) {
      const txt = fs.readFileSync(pfPath, 'utf8').trim();
      if (txt === `${p1.port}\n${p1.proc.pid}`) healed = true;
      else await sleep(100);
    }
    assert(healed, 'server heals poisoned alive-pid port file after probing dead port');

    const p2 = await spawnManagedServer({ HOME: pfHome, PULSE_PORT_FILE: pfPath });
    await sleep(300);
    const afterSecond = fs.readFileSync(pfPath, 'utf8').trim();
    assert(afterSecond === `${p1.port}\n${p1.proc.pid}`,
      'second non-daemon server does not overwrite verified live Pulse port file');

    await stopProc(p2.proc, 'SIGTERM');
    await stopProc(p1.proc, 'SIGTERM');
  }

  console.log('PULSE_SELFTEST=fast blacklist isolation:');
  {
    const stHome = path.join(fakeHome, 'st-home');
    const stBl = path.join(stHome, '.pulse', 'blacklist.json');
    fs.mkdirSync(path.dirname(stBl), { recursive: true });
    const sentinel = JSON.stringify({
      version: 1,
      rev: 4,
      rules: [{ matchType: 'name', pattern: 'sentinel_never_touch', label: 'Sentinel', sig: 'KILL', enabled: true }],
    }) + '\n';
    fs.writeFileSync(stBl, sentinel);

    const stSrv = await spawnManagedServer({ HOME: stHome, PULSE_SELFTEST: 'fast' });
    const blRes = (await getOnPort(stSrv.port, '/api/blacklist')).json();
    assert(blRes.ok === true && blRes.rules.length === 0,
      'PULSE_SELFTEST=fast ignores disk blacklist.json');
    await stopProc(stSrv.proc, 'SIGTERM');
    assert(fs.readFileSync(stBl, 'utf8') === sentinel,
      'PULSE_SELFTEST=fast leaves disk blacklist.json untouched');
  }

  finish();

  function finish() {
    if (done) return;
    done = true;
    for (const c of activeChildren) {
      try { c.kill('SIGKILL'); } catch {}
    }
    fs.rmSync(fakeHome, { recursive: true, force: true });
    console.log(`\nResults: ${passed} passed, ${failed} failed`);
    process.exit(failed ? 1 : 0);
  }
  setTimeout(() => {
    if (!done) {
      console.error('  FAIL: timed out');
      for (const c of activeChildren) {
        try { c.kill('SIGKILL'); } catch {}
      }
      process.exit(1);
    }
  }, 60000);
}

main().catch((e) => { console.error('  FAIL:', e); process.exit(1); });
