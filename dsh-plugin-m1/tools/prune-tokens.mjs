#!/usr/bin/env node
// M4.43 / 指令第 2 条第 4 点；M4.44 起磁盘上只存 sha256(token)。
//
// 背景：agent 每次重启都会 pair 出一个新 token（旧代码里 deviceId 还是随机的
// ulid），于是 tokens.json 长成了 200+ 条永不失效的凭证。插件现在会自己按
// 设备去重，但盘上已有的历史垃圾需要跑一次这个脚本。
//
// 规则（与 hub.js 的 #trimSameDevice 保持一致）：
//   - 已经过期的直接删
//   - 同一个 role + deviceId 只留 expiresAt 最新的 2 条
//     （留 2 条是为了容错：旧连接可能还握着上一条）
//
// 用法：
//   node tools/prune-tokens.mjs                 # 只体检 + 打印计划，不写盘
//   node tools/prune-tokens.mjs --yes           # 先备份 tokens.json.bak-<时间戳>，再写回
//   node tools/prune-tokens.mjs --yes --file <DSH 数据目录>\dsh-plugin-m1\tokens.json
import { copyFileSync, existsSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { homedir } from 'node:os';
import { pathToFileURL } from 'node:url';

const KEEP_PER_DEVICE = 2;

function parseArgs(argv) {
  const options = { yes: false, file: '' };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === '--yes') options.yes = true;
    else if (arg === '--file') options.file = String(argv[i + 1] ?? '');
    else if (arg.startsWith('--file=')) options.file = arg.slice('--file='.length);
  }
  return options;
}

/** 默认路径：与插件 stateDir 同构（<userData>/.dsh/dsh-plugin-m1/tokens.json）。 */
function defaultTokenFile() {
  const candidates = [
    join(homedir(), '.dsh', 'dsh-plugin-m1', 'tokens.json'),
    join(homedir(), '.config', 'dsh', 'dsh-plugin-m1', 'tokens.json'),
  ];
  return candidates.find((path) => existsSync(path)) ?? candidates[0];
}

function expireAt(record) {
  const raw = record?.expiresAt;
  const time = typeof raw === 'string' ? Date.parse(raw) : Number(raw);
  return Number.isFinite(time) ? time : 0;
}

/**
 * 纯函数：给定 token 记录数组，返回清理后的数组 + 统计。
 * 独立导出，测试里直接调，不碰磁盘。
 */
export function pruneTokens(records, { now = Date.now(), keep = KEEP_PER_DEVICE } = {}) {
  const alive = [];
  let expired = 0;
  for (const record of Array.isArray(records) ? records : []) {
    // M4.44：新文件是 tokenHash；老文件是明文 token。两种都认，身份键优先哈希。
    const identity =
      typeof record?.tokenHash === 'string' && record.tokenHash !== ''
        ? record.tokenHash
        : typeof record?.token === 'string'
          ? record.token
          : '';
    if (!record || identity === '') continue;
    if (expireAt(record) <= now) {
      expired += 1;
      continue;
    }
    alive.push(record);
  }

  const groups = new Map();
  for (const record of alive) {
    const key = `${record.role ?? 'app'}|${record.deviceId ?? 'unknown'}`;
    const bucket = groups.get(key);
    if (bucket) bucket.push(record);
    else groups.set(key, [record]);
  }

  const kept = [];
  let dropped = 0;
  for (const bucket of groups.values()) {
    bucket.sort((left, right) => expireAt(right) - expireAt(left));
    kept.push(...bucket.slice(0, keep));
    dropped += Math.max(0, bucket.length - keep);
  }
  kept.sort((left, right) => expireAt(right) - expireAt(left));

  const byRole = {};
  for (const record of kept) {
    const role = record.role ?? 'app';
    byRole[role] = (byRole[role] ?? 0) + 1;
  }

  return {
    kept,
    stats: {
      total: Array.isArray(records) ? records.length : 0,
      kept: kept.length,
      expired,
      dropped,
      byRole,
      groups: groups.size,
    },
  };
}

function main() {
  const options = parseArgs(process.argv.slice(2));
  const file = options.file || defaultTokenFile();
  if (!existsSync(file)) {
    console.error(`找不到 tokens.json：${file}`);
    process.exit(2);
  }

  const raw = readFileSync(file, 'utf8');
  let parsed;
  try {
    parsed = JSON.parse(raw);
  } catch (error) {
    console.error(`tokens.json 不是合法 JSON，先别动它：${error.message}`);
    process.exit(2);
  }
  // 兼容两种形状：直接数组，或 { tokens: [...] }
  const records = Array.isArray(parsed) ? parsed : parsed?.tokens;
  if (!Array.isArray(records)) {
    console.error('tokens.json 里没有 token 数组（期望 [] 或 { "tokens": [] }）');
    process.exit(2);
  }

  const { kept, stats } = pruneTokens(records);
  const stamp = new Date().toISOString().replace(/[:.]/g, '-');
  const backup = `${file}.bak-${stamp}`;

  console.log(`文件：${file}`);
  console.log(
    `现有 ${stats.total} 条 → 保留 ${stats.kept} 条（过期 ${stats.expired}、同设备多余 ${stats.dropped}）`,
  );
  console.log(
    `保留分布：${Object.entries(stats.byRole)
      .map(([role, count]) => `${role} ${count}`)
      .join(' / ')}，覆盖 ${stats.groups} 个设备`,
  );
  console.log(`备份会写到：${backup}`);

  if (!options.yes) {
    console.log('这是预演（没有写盘）。确认无误后加 --yes 再跑一次。');
    return;
  }
  if (kept.length === stats.total) {
    console.log('没有需要清理的记录，未改动文件。');
    return;
  }

  copyFileSync(file, backup);
  writeFileSync(file, `${JSON.stringify(kept, null, 2)}\n`, { encoding: 'utf8', mode: 0o600 });
  console.log(`已写回 ${kept.length} 条；原文件备份在 ${backup}`);
}

// 只有直接 `node tools/prune-tokens.mjs` 才执行；被测试 import 时不动磁盘。
const invokedDirectly =
  process.argv[1] !== undefined &&
  import.meta.url === pathToFileURL(process.argv[1]).href;
if (invokedDirectly) main();
