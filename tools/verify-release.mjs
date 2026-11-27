#!/usr/bin/env node
// M4.44：发布前一致性校验。
//
//   node tools/verify-release.mjs                     # 校验 dist/DeepSeek-Remote-latest.apk
//   node tools/verify-release.mjs --apk <path> --base http://127.0.0.1:8787
//
// 校验四件事，任何一条不满足就退出码 1：
//   1. APK 的 applicationId / versionCode / versionName 能从 aapt2 读出来；
//   2. versionCode 不小于接口里已经发布的版本（防止回滚重发）；
//   3. 接口返回的 size / sha256 与本地 APK 完全一致；
//   4. 接口的 versionName 与 APK 一致。
//
// 为什么单独写一个脚本：这三个数字（versionCode / size / sha256）以前靠手抄，
// 手抄就一定会错一次，错的那次用户装着旧包却以为更新了。

import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { existsSync, readFileSync, statSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const repoRoot = resolve(here, '..');

function arg(name, fallback) {
  const index = process.argv.indexOf(`--${name}`);
  if (index < 0) return fallback;
  const value = process.argv[index + 1];
  return value && !value.startsWith('--') ? value : fallback;
}

const apkPath = resolve(arg('apk', join(repoRoot, 'dist', 'DeepSeek-Remote-latest.apk')));
const baseUrl = arg('base', 'http://127.0.0.1:8787').replace(/\/+$/, '');
const aapt2 = arg(
  'aapt2',
  'C:\\Users\\user\\dsh-tools\\android-sdk\\build-tools\\36.0.0\\aapt2.exe',
);

function fail(message) {
  console.error(`✗ ${message}`);
  process.exit(1);
}

function ok(message) {
  console.log(`✓ ${message}`);
}

if (!existsSync(apkPath)) fail(`找不到 APK：${apkPath}`);

const size = statSync(apkPath).size;
const sha256 = createHash('sha256').update(readFileSync(apkPath)).digest('hex');

let badging;
try {
  badging = execFileSync(aapt2, ['dump', 'badging', apkPath], { encoding: 'utf8' });
} catch (error) {
  fail(`aapt2 读不出 APK 信息：${error.message}`);
}

const packageLine = badging.split('\n').find((line) => line.startsWith('package:'));
if (!packageLine) fail('APK 里没有 package 信息');
const versionCode = Number(/versionCode='(\d+)'/.exec(packageLine)?.[1] ?? NaN);
const versionName = /versionName='([^']*)'/.exec(packageLine)?.[1] ?? '';
const applicationId = /name='([^']*)'/.exec(packageLine)?.[1] ?? '';

if (!Number.isInteger(versionCode)) fail(`versionCode 解析失败：${packageLine}`);
if (!versionName) fail('versionName 解析失败');
ok(`本地 APK：${applicationId} ${versionName} (versionCode ${versionCode})`);
ok(`本地大小 ${size} 字节，sha256 ${sha256}`);

let published;
try {
  const response = await fetch(`${baseUrl}/api/v1/app/version`, {
    signal: AbortSignal.timeout(8000),
  });
  if (!response.ok) fail(`更新接口返回 ${response.status}，没法比对（电脑端插件要先跑起来）`);
  published = await response.json();
} catch (error) {
  fail(`连不上 ${baseUrl}/api/v1/app/version：${error.message}`);
}

if (!published || typeof published !== 'object') fail('更新接口返回的不是 JSON 对象');
ok(`接口已发布：${published.versionName} (versionCode ${published.versionCode})`);

const problems = [];
if (Number(published.versionCode) < versionCode) {
  problems.push(
    `接口里的 versionCode ${published.versionCode} 小于本地 ${versionCode}——手机还看不到这次更新`,
  );
}
if (Number(published.versionCode) > versionCode) {
  problems.push(
    `接口里的 versionCode ${published.versionCode} 大于本地 ${versionCode}——本地包比线上旧`,
  );
}
if (Number(published.size) !== size) {
  problems.push(`size 不一致：接口 ${published.size} / 本地 ${size}`);
}
if (String(published.sha256 ?? '').toLowerCase() !== sha256) {
  problems.push(`sha256 不一致：接口 ${published.sha256} / 本地 ${sha256}`);
}
if (String(published.versionName ?? '') !== versionName) {
  problems.push(`versionName 不一致：接口 ${published.versionName} / 本地 ${versionName}`);
}

if (problems.length > 0) {
  for (const problem of problems) console.error(`✗ ${problem}`);
  console.error('\n先确认 dist 三处副本是同一个文件，并把 APK 放到插件读得到的发布目录。');
  process.exit(1);
}

ok('versionCode / size / sha256 / versionName 四项一致');
