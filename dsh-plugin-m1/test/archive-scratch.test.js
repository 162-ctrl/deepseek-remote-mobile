// M4.11：存档里的「测试临时目录」过滤（isScratchWorkspace）
//
// 插件自测、e2e、契约测试在 agent\.m1ws、agent\.workspaces\contract-... 这类目录里
// 跑出过上百个会话，混进手机端「已存档」分组会把真实项目淹掉。这里从源码截出
// 常量与函数做纯函数验证，并按路径分段判断，确保不会误伤名字里带这些字样的正常项目。

import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';

const source = readFileSync(new URL('../lib/index.js', import.meta.url), 'utf8');

function grabBlock(anchor) {
  const start = source.indexOf(anchor);
  if (start < 0) throw new Error(`找不到 ${anchor}`);
  // 从锚点所在行开始，一直截到分号结束（这两个常量都是单行数组字面量）。
  const end = source.indexOf(';', start);
  if (end < 0) throw new Error(`${anchor} 没有以分号结束`);
  return source.slice(start, end + 1);
}

function grabFunction(name) {
  let start = source.indexOf(`\n  const ${name} = `);
  if (start < 0) start = source.indexOf(`\nfunction ${name}(`);
  if (start < 0) throw new Error(`找不到函数 ${name}`);
  let depth = 0;
  let begun = false;
  for (let i = start; i < source.length; i += 1) {
    const ch = source[i];
    if (ch === '{') {
      depth += 1;
      begun = true;
    } else if (ch === '}') {
      depth -= 1;
      if (begun && depth === 0) return source.slice(start, i + 1);
    }
  }
  throw new Error(`函数 ${name} 的花括号没配平`);
}

const segmentsBlock = grabBlock('const ARCHIVE_SKIP_SEGMENTS = [');
const prefixesBlock = grabBlock('const ARCHIVE_SKIP_PREFIXES = [');

const factory = new Function(
  `${segmentsBlock}\n${prefixesBlock}\n${grabFunction('isScratchWorkspace')}\nreturn isScratchWorkspace;`,
);
const isScratchWorkspace = factory();

test('测试/e2e 临时目录被判为 scratch', () => {
  const scratch = [
    '<项目根>\\agent\\.m1ws',
    '<项目根>\\agent\\.m1ws\\phase-c',
    '<项目根>\\agent\\.workspaces\\contract-2026-10-31T04-22-15-155Z',
    '<项目根>\\agent\\.workspaces\\e2e-2026-10-31T04-28-48-670Z',
    '<项目根>\\agent\\.workspaces\\probe-approval-2026-10-31T04-16-35-812Z',
    '<项目根>\\agent\\.workspaces\\reject-trigger-2026-10-31T04-24-45-601Z',
    '<项目根>\\.tmp',
    '<项目根>\\node_modules\\foo',
    'C:/Users/user/project/.dart_tool/build',
    '<项目根>\\agent\\.M1WS',
  ];
  for (const path of scratch) {
    assert.equal(isScratchWorkspace(path), true, `应判为临时目录：${path}`);
  }
});

test('真实工作区不会被误判', () => {
  const real = [
    '<项目根>',
    '<项目根>\\docs\\research',
    'D:\\Projects\\示例项目C',
    'D:\\Projects\\示例项目B',
    'D:\\Projects\\课程\\上册\\数据结构实验',
    'D:\\Projects\\课程\\上册\\面向对象程序设计\\课程设计',
    'D:\\Projects\\课程\\上册\\计算方法实验\\实验二',
    'D:\\Projects\\测试',
    'C:\\Users\\user',
    'D:\\Projects\\照片',
    'D:\\Projects\\文本转视频',
    'D:\\Projects\\token消耗实时显示',
  ];
  for (const path of real) {
    assert.equal(isScratchWorkspace(path), false, `不应判为临时目录：${path}`);
  }
});

test('空值与异常输入不抛异常', () => {
  for (const value of [undefined, null, '', '   ', '\\', '/']) {
    assert.equal(isScratchWorkspace(value), false);
  }
});

test('扫描与列表都接上了过滤（源码层面）', () => {
  // 用「函数名到下一个顶层 `\n  const ` 声明」之间的源码片段做断言，
  // 比按花括号截取更稳（函数体里有对象字面量与模板字符串）。
  const sliceBetween = (name, nextAnchor) => {
    const start = source.indexOf(`const ${name} = `);
    if (start < 0) throw new Error(`找不到 const ${name} = `);
    const end = source.indexOf(nextAnchor, start);
    if (end < 0) throw new Error(`找不到 ${nextAnchor}`);
    return source.slice(start, end);
  };
  const scan = sliceBetween('scanSessionsOnDisk', 'const listArchivedSessions');
  assert.match(scan, /isScratchWorkspace\(record\.workspace\)/, '磁盘扫描应跳过临时目录');
  const list = sliceBetween('listArchivedSessions', 'const getArchivedSession');
  assert.match(list, /isScratchWorkspace\(record\.workspace\)/, '列表输出应再挡一层（含存量记录）');
});
