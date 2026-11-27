import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';

import { AppUpdate, readUpdateNoteList } from '../lib/appupdate.js';

function makeProject(notes) {
  const dir = mkdtempSync(join(tmpdir(), 'm1-appupdate-'));
  mkdirSync(join(dir, 'docs'), { recursive: true });
  if (notes !== undefined) {
    writeFileSync(join(dir, 'docs', 'UPDATE_NOTES.md'), notes, 'utf8');
  }
  const apk = join(dir, 'app-release.apk');
  writeFileSync(apk, 'not-a-real-apk');
  return { dir, apk };
}

test('M4.63 更新说明从 docs/UPDATE_NOTES.md 自动发布', () => {
  const { dir, apk } = makeProject([
    '# 更新说明',
    '',
    '## 0.4.58+79（2026-11-27）— 启动自愈',
    '',
    '**一句话**：闪退后会自己清掉坏存档。',
    '',
    '- 连续三次没走到第一帧就复位。',
    '',
    '## 0.4.57+78（2026-11-25）— 接收文件',
    '',
    '- 这一条不该被选中。',
    '',
  ].join('\n'));
  const update = new AppUpdate({
    apkPath: apk,
    projectDir: dir,
    versionCode: 79,
    versionName: '0.4.58-m4.58',
  });
  const info = update.versionPayload();
  assert.equal(info.versionCode, 79);
  assert.match(info.notes, /闪退后会自己清掉坏存档/);
  assert.match(info.notes, /连续三次没走到第一帧就复位/);
  assert.doesNotMatch(info.notes, /这一条不该被选中/);
  assert.doesNotMatch(info.notes, /^## /m);
});

test('M4.63 没有对应版本段时 notes 为空', () => {
  const { dir, apk } = makeProject('## 0.4.57+78（2026-11-25）— 接收文件\n\n- 旧版本。\n');
  const update = new AppUpdate({
    apkPath: apk,
    projectDir: dir,
    versionCode: 79,
    versionName: '0.4.58-m4.58',
  });
  assert.equal(update.versionPayload().notes, '');
});

test('M4.63 显式配置的 notes 优先于文件', () => {
  const { dir, apk } = makeProject('## 0.4.58+79（2026-11-27）— 文件里的\n');
  const update = new AppUpdate({
    apkPath: apk,
    projectDir: dir,
    versionCode: 79,
    versionName: '0.4.58-m4.58',
    notes: '配置里的说明',
  });
  assert.equal(update.versionPayload().notes, '配置里的说明');
});

test('M4.66 更新日志列表按段拆出版本、日期、标题与正文', () => {
  const { dir } = makeProject([
    '# 更新说明',
    '',
    '## 0.4.60（2026-11-28）— 充值页与更新日志',
    '',
    '**一句话**：充值能进 App 里看了。',
    '',
    '- 功能页多了「更新日志」。',
    '',
    '## 0.4.58+79（2026-11-27）— 启动自愈',
    '',
    '- 连续三次没走到第一帧就复位。',
    '',
  ].join('\n'));
  const notes = readUpdateNoteList(dir);
  assert.equal(notes.length, 2);
  assert.equal(notes[0].version, '0.4.60');
  assert.equal(notes[0].date, '2026-11-28');
  assert.equal(notes[0].title, '充值页与更新日志');
  assert.match(notes[0].body, /充值能进 App 里看了/);
  assert.match(notes[0].body, /更新日志/);
  assert.doesNotMatch(notes[0].body, /连续三次没走到第一帧/);
  assert.equal(notes[1].version, '0.4.58+79');
  assert.equal(notes[1].title, '启动自愈');
});

test('M4.66 没有 UPDATE_NOTES.md 时返回空列表', () => {
  const { dir } = makeProject(undefined);
  assert.deepEqual(readUpdateNoteList(dir), []);
});
