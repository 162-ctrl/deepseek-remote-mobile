// 调试用：在某个 session 日志里按关键字/类型找事件（逐帧 zstd 解压）。
// 用法：
//   node tools/grep-session-log.mjs <sessionId> <keyword> [window]
//   node tools/grep-session-log.mjs <sessionId> --type question/request
import { readFileSync, readdirSync } from 'node:fs';
import { join } from 'node:path';
import zlib from 'node:zlib';

const ROOT = 'C:/Users/user/.dsh/sessions';
const id = process.argv[2];
const arg = process.argv[3] ?? '';
const window = Number(process.argv[4] ?? 0);
if (!id || !arg) {
  console.error('usage: node tools/grep-session-log.mjs <sessionId> <keyword|--type TYPE> [window]');
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
const events = text
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
console.log(`events ${events.length}`);

const typeFilter = arg.startsWith('--type') ? arg.slice('--type'.length).trim() : '';
const hits = [];
events.forEach((event, index) => {
  const raw = JSON.stringify(event);
  const matched = typeFilter ? event.type === typeFilter : raw.includes(arg);
  if (matched) hits.push(index);
});
console.log(`hits ${hits.length}`);

const show = (from, to) => {
  for (let k = from; k <= to && k < events.length; k += 1) {
    const event = events[k];
    console.log(String(event.seq).padStart(5), event.type, JSON.stringify(event.data ?? null).slice(0, 900));
  }
};

hits.slice(0, 6).forEach((index) => {
  console.log('---');
  show(Math.max(0, index - window), Math.min(events.length - 1, index + window));
});
