// Generates the Pulse DMG background image (1320x800 @ 144 DPI = 660x400 pt).
// Pure Node (zlib) — zero dependencies. Usage: node make-dmg-bg.mjs <out.png>
import { deflateSync } from 'node:zlib';
import { writeFileSync } from 'node:fs';

const W = 1320;
const H = 800;
const px = Buffer.alloc(W * H * 4);

function clamp01(v) {
  return v < 0 ? 0 : v > 1 ? 1 : v;
}

function smoothstep(e0, e1, x) {
  const t = clamp01((x - e0) / (e1 - e0));
  return t * t * (3 - 2 * t);
}

function distToSeg(x, y, ax, ay, bx, by) {
  const vx = bx - ax, vy = by - ay;
  const wx = x - ax, wy = y - ay;
  const len2 = vx * vx + vy * vy;
  const t = len2 > 0 ? clamp01((wx * vx + wy * vy) / len2) : 0;
  const dx = ax + t * vx - x;
  const dy = ay + t * vy - y;
  return Math.sqrt(dx * dx + dy * dy);
}

// Icon centers in @2x coordinates (matching Finder positions {185, 195} and {475, 195})
const LEFT_X = 370;
const RIGHT_X = 950;
const ICON_Y = 390;

// Subtle center chevron arrow segments (between x=590 and x=730)
const chevrons = [
  // Three sleek forward chevrons: › › ›
  [[602, ICON_Y - 26], [628, ICON_Y], [602, ICON_Y + 26]],
  [[648, ICON_Y - 26], [674, ICON_Y], [648, ICON_Y + 26]],
  [[694, ICON_Y - 26], [720, ICON_Y], [694, ICON_Y + 26]],
];

// Subtle top-center mini pulse waveform emblem (at y=110)
const emblemPts = [
  [580, 112],
  [626, 112],
  [644, 68],
  [664, 152],
  [684, 88],
  [702, 112],
  [740, 112],
];

for (let y = 0; y < H; y++) {
  const vNorm = y / H;
  for (let x = 0; x < W; x++) {
    const idx = (y * W + x) * 4;

    // Base dark background (#0b0d12 top -> #12151d bottom)
    let r = 11 * (1 - vNorm) + 18 * vNorm;
    let g = 13 * (1 - vNorm) + 21 * vNorm;
    let b = 18 * (1 - vNorm) + 29 * vNorm;

    // Subtle warm radial spotlight behind Pulse.app
    const dl = Math.hypot((x - LEFT_X) / 260, (y - ICON_Y) / 240);
    if (dl < 1) {
      const gl = Math.pow(1 - dl, 2.2) * 0.11;
      r += (255 - r) * gl;
      g += (159 - g) * gl * 0.85;
      b += (67 - b) * gl * 0.5;
    }

    // Subtle cool radial spotlight behind Applications
    const dr = Math.hypot((x - RIGHT_X) / 260, (y - ICON_Y) / 240);
    if (dr < 1) {
      const gr = Math.pow(1 - dr, 2.2) * 0.08;
      r += (77 - r) * gr;
      g += (159 - g) * gr;
      b += (255 - b) * gr;
    }

    // Subtle dot grid (every 40px) faded toward edges
    if (x % 40 < 2 && y % 40 < 2) {
      const edgeX = smoothstep(40, 220, x) * (1 - smoothstep(W - 220, W - 40, x));
      const edgeY = smoothstep(40, 180, y) * (1 - smoothstep(H - 180, H - 40, y));
      const dotA = 0.045 * edgeX * edgeY;
      r += (139 - r) * dotA;
      g += (148 - g) * dotA;
      b += (167 - b) * dotA;
    }

    // Subtle rounded-square drop-zone halos around both icon slots
    for (const [cx, isLeft] of [[LEFT_X, true], [RIGHT_X, false]]) {
      const half = 136;
      const rad = 36;
      const dx = Math.max(0, Math.abs(x - cx) - (half - rad));
      const dy = Math.max(0, Math.abs(y - ICON_Y) - (half - rad));
      const boxDist = Math.hypot(dx, dy) - rad;
      if (Math.abs(boxDist) < 2.5) {
        const ringA = (1 - smoothstep(0, 2.2, Math.abs(boxDist))) * (isLeft ? 0.18 : 0.13);
        const cr = isLeft ? 255 : 139;
        const cg = isLeft ? 159 : 148;
        const cb = isLeft ? 67 : 167;
        r += (cr - r) * ringA;
        g += (cg - g) * ringA;
        b += (cb - b) * ringA;
      }
    }

    // Center forward chevrons (progressive opacity: 0.35 -> 0.6 -> 0.95)
    const opacities = [0.35, 0.62, 0.95];
    for (let c = 0; c < chevrons.length; c++) {
      const [p0, p1, p2] = chevrons[c];
      const d = Math.min(
        distToSeg(x, y, p0[0], p0[1], p1[0], p1[1]),
        distToSeg(x, y, p1[0], p1[1], p2[0], p2[1])
      );
      if (d < 18) {
        const glow = Math.exp(-d * 0.22) * 0.22 * opacities[c];
        r += (255 - r) * glow;
        g += (159 - g) * glow;
        b += (67 - b) * glow;
        if (d < 5.5) {
          const core = (1 - smoothstep(3.2, 5.2, d)) * opacities[c];
          r = r * (1 - core) + 255 * core;
          g = g * (1 - core) + 159 * core;
          b = b * (1 - core) + 67 * core;
        }
      }
    }

    // Top-center subtle pulse waveform emblem
    if (y < 180 && x > 560 && x < 760) {
      let md = Infinity;
      for (let i = 0; i < emblemPts.length - 1; i++) {
        const d = distToSeg(
          x, y,
          emblemPts[i][0], emblemPts[i][1],
          emblemPts[i + 1][0], emblemPts[i + 1][1]
        );
        if (d < md) md = d;
      }
      if (md < 20) {
        const glow = Math.exp(-md * 0.2) * 0.25;
        r += (255 - r) * glow;
        g += (159 - g) * glow;
        b += (67 - b) * glow;
        if (md < 4.5) {
          const core = (1 - smoothstep(2.5, 4.3, md)) * 0.85;
          r = r * (1 - core) + 255 * core;
          g = g * (1 - core) + 159 * core;
          b = b * (1 - core) + 67 * core;
        }
      }
    }

    px[idx]     = Math.round(r);
    px[idx + 1] = Math.round(g);
    px[idx + 2] = Math.round(b);
    px[idx + 3] = 255;
  }
}

// --- encode PNG with 144 DPI (5669 px/m) pHYs chunk for Retina Finder rendering ---
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
const raw = Buffer.alloc(H * (W * 4 + 1));
for (let y = 0; y < H; y++) {
  raw[y * (W * 4 + 1)] = 0;
  px.copy(raw, y * (W * 4 + 1) + 1, y * W * 4, (y + 1) * W * 4);
}
const ihdr = Buffer.alloc(13);
ihdr.writeUInt32BE(W, 0);
ihdr.writeUInt32BE(H, 4);
ihdr[8] = 8;
ihdr[9] = 6;
const phys = Buffer.alloc(9);
phys.writeUInt32BE(5669, 0); // 144 DPI
phys.writeUInt32BE(5669, 4);
phys[8] = 1; // meters
const png = Buffer.concat([
  Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
  chunk('IHDR', ihdr),
  chunk('pHYs', phys),
  chunk('IDAT', deflateSync(raw, { level: 9 })),
  chunk('IEND', Buffer.alloc(0)),
]);
const outPath = process.argv[2] || 'dmg-background.png';
writeFileSync(outPath, png);
console.log('wrote', outPath);
