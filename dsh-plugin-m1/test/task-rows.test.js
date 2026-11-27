import test from 'node:test';
import assert from 'node:assert/strict';

import { HH_MM, labelAndSortTasks, labelDuplicateTitles, sortByLastTime } from '../lib/task-rows.js';

const row = (title, lastTime, extra = {}) => ({ title, lastTime, ...extra });

test('sortByLastTime 按最后事件时间倒序（最近的对话在最上面）', () => {
  const rows = [row('旧会话', 1000), row('新会话', 5000), row('中间', 3000)];
  assert.deepEqual(sortByLastTime(rows).map((item) => item.title), ['新会话', '中间', '旧会话']);
});

test('sortByLastTime 无时间的行排在最后并保持原有相对顺序', () => {
  const rows = [row('无时间A', 0), row('有时间', 2000), row('无时间B', 0)];
  assert.deepEqual(sortByLastTime(rows).map((item) => item.title), ['有时间', '无时间A', '无时间B']);
});

test('labelDuplicateTitles 只给重名会话补 HH:mm', () => {
  const rows = [row('deepseek手机端', 1730000000000), row('deepseek手机端', 1730000060000), row('别的会话', 1730000090000)];
  const labels = labelDuplicateTitles(rows).map((item) => item.title);
  assert.equal(labels[0].startsWith('deepseek手机端 · '), true);
  assert.equal(labels[1].startsWith('deepseek手机端 · '), true);
  assert.notEqual(labels[0], labels[1]);
  assert.equal(labels[2], '别的会话');
});

test('labelAndSortTasks 组合排序、补名并截断条数', () => {
  const rows = [];
  for (let index = 0; index < 60; index += 1) {
    rows.push(row(index % 2 === 0 ? '同名会话' : `会话${index}`, 1_700_000_000_000 + index * 1000));
  }
  const result = labelAndSortTasks(rows, 50);
  assert.equal(result.length, 50);
  // 最新的一行（index 59，秒级递增最大）在最前
  assert.equal(result[0].title, '会话59');
  assert.ok(result.every((item) => typeof item.lastTime === 'number'));
});

test('labelAndSortTasks 接受空输入', () => {
  assert.deepEqual(labelAndSortTasks([]), []);
  assert.deepEqual(labelAndSortTasks(null), []);
});

test('HH_MM 格式化合法毫秒，非法值返回空串', () => {
  const value = HH_MM(Date.parse('2026-11-11T19:43:00+08:00'));
  assert.match(value, /^\d{2}:\d{2}$/);
  assert.equal(HH_MM(0), '');
  assert.equal(HH_MM(-1), '');
  assert.equal(HH_MM('nope'), '');
});
