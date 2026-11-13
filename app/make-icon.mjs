// Generates the Pulse app icon: macOS squircle with dark glass surface and
// glowing #ff9f43 heartbeat waveform.
// Pure Node (zlib) — writes a 1024x1024 RGBA PNG. Usage: node make-icon.mjs <out.png>
import { deflateSync } from 'node:zlib';
import { writeFileSync } from 'node:fs';

const S = 1024;
const px = Buffer.alloc(S * S * 4); // RGBA, straight alpha

// Squircle geometry (macOS Big Sur+ proportions: ~824x824 body inside 1024x1024)
const CX = 512;
const CY = 504; // slight upward shift to leave room for the bottom drop shadow
const HALF = 412; // 824 / 2
const SQUIRCLE_EXP = 4.6;

// Heartbeat waveform polyline (centered at CY)
const pts = [
  [212, CY],
  [356, CY],
  [420, CY - 196],
  [488, CY + 180],
  [558, CY - 110],
  [618, CY],
  [812, CY],
];

function clamp01(v) {
  return v < 0 ? 0 : v > 1 ? 1 : v;
}

function smoothstep(edge0, edge1, x) {
  const t = clamp01((x - edge0) / (edge1 - edge0));
  return t * t * (3 - 2 * t);
}

// Signed distance (in pixels, approximate) to superellipse boundary.
// Negative = inside, positive = outside.
function squircleSDF(x, y, half, exp) {
  const dx = Math.abs(x - CX) / half;
  const dy = Math.abs(y - CY) / half;
  const r = Math.pow(Math.pow(dx, exp) + Math.pow(dy, exp), 1 / exp);
  return (r - 1) * half;
}

// Minimum Euclidean distance from (x, y) to the waveform polyline.
function waveformDist(x, y) {
  let minD2 = Infinity;
  for (let i = 0; i < pts.length - 1; i++) {
    const ax = pts[i][0], ay = pts[i][1];
    const bx = pts[i + 1][0], by = pts[i + 1][1];
    const vx = bx - ax, vy = by - ay;
    const wx = x - ax, wy = y - ay;
    const len2 = vx * vx + vy * vy;
    const t = len2 > 0 ? clamp01((wx * vx + wy * vy) / len2) : 0;
    const px = ax + t * vx - x;
    const py = ay + t * vy - y;
    const d2 = px * px + py * py;
    if (d2 < minD2) minD2 = d2;
  }
  return Math.sqrt(minD2);
}

function blendOver(idx, r, g, b, a) {
  if (a <= 0) return;
  const da = clamp01(a);
  const sa = px[idx + 3] / 255;
  const oa = da + sa * (1 - da);
  if (oa <= 0) return;
  px[idx]     = Math.round((r * da + px[idx]     * sa * (1 - da)) / oa);
  px[idx + 1] = Math.round((g * da + px[idx + 1] * sa * (1 - da)) / oa);
  px[idx + 2] = Math.round((b * da + px[idx + 2] * sa * (1 - da)) / oa);
  px[idx + 3] = Math.round(oa * 255);
}

for (let y = 0; y < S; y++) {
  const vNorm = clamp01((y - (CY - HALF)) / (HALF * 2));
  for (let x = 0; x < S; x++) {
    const idx = (y * S + x) * 4;

    // 1. Soft ambient drop shadow beneath the squircle
    const shadowDy = (y - (CY + 20)) / HALF;
    const shadowDx = (x - CX) / HALF;
    const shadowR = Math.pow(
      Math.pow(Math.abs(shadowDx), SQUIRCLE_EXP) + Math.pow(Math.abs(shadowDy), SQUIRCLE_EXP),
      1 / SQUIRCLE_EXP
    );
    const shadowDist = (shadowR - 1) * HALF;
    if (shadowDist < 56) {
      const shA = (1 - smoothstep(-10, 56, shadowDist)) * 0.42;
      if (shA > 0.002) {
        blendOver(idx, 4, 6, 10, shA);
      }
    }

    // 2. Squircle body mask (1.5px anti-aliased edge)
    const sd = squircleSDF(x, y, HALF, SQUIRCLE_EXP);
    if (sd > 1.5) continue;
    const bodyAlpha = 1 - smoothstep(-1.2, 1.2, sd);

    // Base dark glass gradient (#1a1f2d top -> #0c0f16 bottom)
    let r = 26 * (1 - vNorm) + 12 * vNorm;
    let g = 31 * (1 - vNorm) + 15 * vNorm;
    let b = 45 * (1 - vNorm) + 22 * vNorm;

    // Subtle radial warm ambient glow behind the waveform center
    const gx = (x - CX) / 380;
    const gy = (y - (CY - 12)) / 340;
    const gDist = Math.sqrt(gx * gx + gy * gy);
    if (gDist < 1) {
      const glow = Math.pow(1 - gDist, 2.2) * 0.14;
      r += (255 - r) * glow;
      g += (159 - g) * glow * 0.85;
      b += (67 - b) * glow * 0.55;
    }

    // Subtle horizontal telemetry hairlines (baseline + upper/lower guides)
    const onBaseline = Math.abs(y - CY) < 0.75;
    const onGuide = Math.abs(y - (CY - 160)) < 0.6 || Math.abs(y - (CY + 160)) < 0.6;
    if ((onBaseline || onGuide) && x > CX - 340 && x < CX + 340) {
      const edgeFade = smoothstep(CX - 340, CX - 260, x) * (1 - smoothstep(CX + 260, CX + 340, x));
      const lineA = (onBaseline ? 0.055 : 0.028) * edgeFade;
      r += (232 - r) * lineA;
      g += (236 - g) * lineA;
      b += (244 - b) * lineA;
    }

    // Crisp inner specular rim (brighter along top edge, subtle along bottom)
    if (sd > -3.5 && sd <= 1.2) {
      const rimMask = smoothstep(-3.5, -1.2, sd) * (1 - smoothstep(-0.2, 1.2, sd));
      const topHighlight = 0.14 * Math.pow(1 - vNorm, 1.4) + 0.035;
      const rimA = rimMask * topHighlight;
      r += (235 - r) * rimA;
      g += (240 - g) * rimA;
      b += (255 - b) * rimA;
    }

    // 3. Heartbeat waveform (bloom + tight glow + core + subtle hot inner highlight)
    const d = waveformDist(x, y);
    if (d < 78) {
      // Wide warm bloom
      const bloom = Math.exp(-d * 0.055) * 0.30;
      r += (255 - r) * bloom;
      g += (145 - g) * bloom;
      b += (45 - b) * bloom;

      // Tight intense glow
      const tight = Math.exp(-Math.max(0, d - 13) * 0.14) * 0.42;
      r += (255 - r) * tight;
      g += (165 - g) * tight;
      b += (72 - b) * tight;

      // Core stroke (radius 15px -> 30px thick, anti-aliased)
      if (d < 16.5) {
        const coreA = 1 - smoothstep(13.8, 16.2, d);
        // Subtle inner highlight in the center of the stroke
        const inner = (1 - smoothstep(0, 7.5, d)) * 0.32;
        const cr = 255;
        const cg = 159 + (214 - 159) * inner;
        const cb = 67 + (150 - 67) * inner;
        r = r * (1 - coreA) + cr * coreA;
        g = g * (1 - coreA) + cg * coreA;
        b = b * (1 - coreA) + cb * coreA;
      }
    }

    blendOver(idx, Math.round(r), Math.round(g), Math.round(b), bodyAlpha);
  }
}

// --- encode PNG ---
const crcTable = (() => {
  const t = new Uint32Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    t[n] = c >>> 0;
  }
  return t;
})();
function crc32(buf) {
  let c = 0xffffffff;
  for (let i = 0; i < buf.length; i++) c = crcTable[(c ^ buf[i]) & 0xff] ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
}
function chunk(type, data) {
  const len = Buffer.alloc(4);
  len.writeUInt32BE(data.length);
  const body = Buffer.concat([Buffer.from(type, 'ascii'), data]);
  const crc = Buffer.alloc(4);
  crc.writeUInt32BE(crc32(body));
  return Buffer.concat([len, body, crc]);
}
const raw = Buffer.alloc(S * (S * 4 + 1));
for (let y = 0; y < S; y++) {
  raw[y * (S * 4 + 1)] = 0; // filter: none
  px.copy(raw, y * (S * 4 + 1) + 1, y * S * 4, (y + 1) * S * 4);
}
const ihdr = Buffer.alloc(13);
ihdr.writeUInt32BE(S, 0);
ihdr.writeUInt32BE(S, 4);
ihdr[8] = 8;
ihdr[9] = 6; // 8-bit RGBA
const png = Buffer.concat([
  Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
  chunk('IHDR', ihdr),
  chunk('IDAT', deflateSync(raw, { level: 9 })),
  chunk('IEND', Buffer.alloc(0)),
]);
const outPath = process.argv[2] || 'Pulse-1024.png';
writeFileSync(outPath, png);
console.log('wrote', outPath);
