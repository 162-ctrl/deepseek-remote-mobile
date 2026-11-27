// 调试用：解压并打印某个 session 日志的事件（逐帧 zstd）。
// 用法：node tools/dump-session-log.mjs <sessionId> [tail]
import { readFileSync, readdirSync, statSync } from 'node:fs';
import { join } from 'node:path';
import zlib from 'node:zlib';

const ROOT = 'C:/Users/user/.dsh/sessions';
const id = process.argv[2];
const tail = Number(process.argv[3] ?? 20);
if (!id) {
  console.error('usage: node tools/dump-session-log.mjs <sessionId> [tail]');
  process.exit(2);
}

const findDir = (base, depth) => {
  if (depth > 3) return null;
  let entries = [];
  try {
    entries = readdirSync(base, { withFileTypes: true });
  } catch {
    return null;
  }
  for (const entry of entries) {
    if (!entry.isDirectory()) continue;
    const full = join(base, entry.name);
    if (entry.name === id) return full;
    const nested = findDir(full, depth + 1);
    if (nested) return nested;
  }
  return null;
};

const dir = findDir(ROOT, 0);
if (!dir) {
  console.error('session dir not found');
  process.exit(1);
}
const files = readdirSync(dir).filter((name) => name.startsWith('session.v') && name.endsWith('.zstd'));
files.sort();
const file = join(dir, files[files.length - 1]);

const buf = readFileSync(file);
const frames = [];
let i = 0;
while (i < buf.length - 3) {
  if (!(buf[i] === 0x28 && buf[i + 1] === 0xb5 && buf[i + 2] === 0x2f && buf[i + 3] === 0xfd)) break;
  const start = i;
  i += 4;
  const fhd = buf[i];
  const fcs = fhd >> 6;
  const single = (fhd >> 5) & 1;
  const d = fhd & 3;
  const dictSize = d === 3 ? 4 : d === 2 ? 2 : d === 1 ? 1 : 0;
  i += 1;
  if (!single) i += 1;
  i += 4;
  i += dictSize;
  const fcsSize = fcs === 0 ? (single ? 1 : 0) : fcs === 1 ? 2 : fcs === 2 ? 4 : 8;
  i += fcsSize;
  let end = i;
  while (end < buf.length - 3) {
    if (buf[end] === 0x28 && buf[end + 1] === 0xb5 && buf[end + 2] === 0x2f && buf[end + 3] === 0xfd) break;
    end += 1;
  }
  frames.push(buf.subarray(start, end));
  i = end;
}

let text = '';
for (const frame of frames) {
  try {
    text += zlib.zstdDecompressSync(frame).toString('utf8');
  } catch {
    /* 跳过损坏帧 */
  }
}
const lines = text
  .split('\n')
  .filter(Boolean)
  .map((line) => {
    try {
      return JSON.parse(line);
    } catch {
      return null;
    }
  })
  .filter(Boolean);

console.log(`file ${file}`);
console.log(`size ${statSync(file).size} events ${lines.length}`);
for (const event of lines.slice(-tail)) {
  console.log(String(event.seq).padStart(5), event.type, JSON.stringify(event.data ?? null).slice(0, 400));
}
