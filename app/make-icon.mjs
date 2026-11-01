// Generates the Pulse app icon: dark rounded square + orange heartbeat waveform.
// Pure Node (zlib) — writes a 1024x1024 RGBA PNG. Usage: node make-icon.mjs <out.png>
import { deflateSync } from 'node:zlib';
import { writeFileSync } from 'node:fs';

const S = 1024;
const px = Buffer.alloc(S * S * 4); // RGBA, premultiplied-free straight alpha

function blend(x, y, r, g, b, a) {
  if (x < 0 || y < 0 || x >= S || y >= S || a <= 0) return;
  const i = (y * S + x) * 4;
  const da = a / 255, sa = px[i + 3] / 255;
  const oa = da + sa * (1 - da);
  if (oa <= 0) return;
  px[i] = Math.round((r * da + px[i] * sa * (1 - da)) / oa);
  px[i + 1] = Math.round((g * da + px[i + 1] * sa * (1 - da)) / oa);
  px[i + 2] = Math.round((b * da + px[i + 2] * sa * (1 - da)) / oa);
  px[i + 3] = Math.round(oa * 255);
}

// --- background: rounded square with a subtle vertical gradient ---
const rad = 224;
for (let y = 0; y < S; y++) {
  for (let x = 0; x < S; x++) {
    const dx = x < rad ? rad - x : (x > S - 1 - rad ? x - (S - 1 - rad) : 0);
    const dy = y < rad ? rad - y : (y > S - 1 - rad ? y - (S - 1 - rad) : 0);
    if (dx * dx + dy * dy <= rad * rad) {
      const t = y / S;
      blend(x, y, 18 + t * 8, 21 + t * 8, 30 + t * 10, 255);
    }
  }
}

// --- heartbeat waveform ---
const pts = [
  [128, 512], [340, 512], [404, 296], [468, 692], [532, 388], [596, 512], [896, 512],
];
function waveY(x) {
  for (let i = 0; i < pts.length - 1; i++) {
    const [x0, y0] = pts[i], [x1, y1] = pts[i + 1];
    if (x >= x0 && x <= x1) {
      const t = (x - x0) / (x1 - x0);
      return y0 + (y1 - y0) * t;
    }
  }
  return null;
}
for (let x = 128; x <= 896; x++) {
  const y = waveY(x);
  if (y == null) continue;
  const yi = Math.round(y);
  for (let o = -34; o <= 34; o++) { // soft glow
    const a = Math.round(70 * (1 - Math.abs(o) / 34));
    if (a > 0) blend(x, yi + o, 255, 159, 67, a);
  }
  for (let o = -13; o <= 13; o++) blend(x, yi + o, 255, 159, 67, 255); // core
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
  const len = Buffer.alloc(4); len.writeUInt32BE(data.length);
  const body = Buffer.concat([Buffer.from(type, 'ascii'), data]);
  const crc = Buffer.alloc(4); crc.writeUInt32BE(crc32(body));
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
ihdr[8] = 8; ihdr[9] = 6; // 8-bit RGBA
const png = Buffer.concat([
  Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
  chunk('IHDR', ihdr),
  chunk('IDAT', deflateSync(raw, { level: 9 })),
  chunk('IEND', Buffer.alloc(0)),
]);
writeFileSync(process.argv[2] || 'Pulse-1024.png', png);
console.log('wrote', process.argv[2] || 'Pulse-1024.png');
