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

function get(p) {
  return new Promise((res, rej) => {
    http.get({ host: '127.0.0.1', port: PORT, path: p }, (r) => {
      let b = '';
      r.on('data', (c) => (b += c));
      r.on('end', () => res({ code: r.statusCode, json: () => JSON.parse(b) }));
    }).on('error', rej);
  });
}
function post(p, body) {
  return new Promise((res, rej) => {
    const req = http.request({ host: '127.0.0.1', port: PORT, path: p, method: 'POST',
      headers: { 'Content-Type': 'application/json' } }, (r) => {
      let b = '';
      r.on('data', (c) => (b += c));
      r.on('end', () => res({ code: r.statusCode, json: () => JSON.parse(b) }));
    });
    req.on('error', rej);
    req.end(JSON.stringify(body));
  });
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function main() {
  const child = spawn(process.execPath, [path.join(__dirname, 'server.js')], {
    env: { ...process.env, HOME: fakeHome, PORT: String(PORT) },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  child.on('exit', (c) => { if (!done) { failed++; console.error(`  FAIL: server exited early (code ${c})`); finish(); } });
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

  finish();

  function finish() {
    if (done) return;
    done = true;
    child.kill('SIGKILL');
    fs.rmSync(fakeHome, { recursive: true, force: true });
    console.log(`\nResults: ${passed} passed, ${failed} failed`);
    process.exit(failed ? 1 : 0);
  }
  setTimeout(() => { if (!done) { console.error('  FAIL: timed out'); child.kill('SIGKILL'); process.exit(1); } }, 45000);
}

main().catch((e) => { console.error('  FAIL:', e); process.exit(1); });
