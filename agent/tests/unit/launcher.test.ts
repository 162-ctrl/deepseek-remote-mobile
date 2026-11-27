import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import {
  ACP_COMMAND_ARGS,
  buildAcpEnv,
  discoverDshInstall,
  findDshCmdOnPath,
} from '../../src/harness/acp/launcher.ts';
import { HarnessError } from '../../src/harness/errors.ts';

describe('findDshCmdOnPath', () => {
  it('在 PATH 中找到 dsh.cmd', () => {
    const dir = mkdtempSync(join(tmpdir(), 'm0-launcher-'));
    try {
      const cmd = join(dir, 'dsh.cmd');
      writeFileSync(cmd, '@echo off\n', 'utf8');
      assert.equal(findDshCmdOnPath({ PATH: `C:\\nope;${dir}` }), cmd);
      assert.equal(findDshCmdOnPath({ PATH: 'C:\\nope' }), null);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});

describe('buildAcpEnv', () => {
  it('只透传运行必需变量，不传任何密钥类变量', () => {
    const env = buildAcpEnv({
      PATH: 'C:\\bin',
      DSH_HOME: 'C:\\Users\\x\\.dsh',
      DEEPSEEK_API_KEY: 'sk-secret',
      FOO: 'bar',
      SYSTEMROOT: 'C:\\Windows',
    });
    assert.equal(env['PATH'], 'C:\\bin');
    assert.equal(env['DSH_HOME'], 'C:\\Users\\x\\.dsh');
    assert.equal(env['ELECTRON_RUN_AS_NODE'], '1');
    assert.equal(env['NO_COLOR'], '1');
    assert.equal(env['DEEPSEEK_API_KEY'], undefined);
    assert.equal(env['FOO'], undefined);
  });

  it('extraEnv 可显式覆盖（用于测试时隔离 DSH_HOME）', () => {
    const env = buildAcpEnv({ PATH: 'C:\\bin' }, { DSH_HOME: 'C:\\tmp-home' });
    assert.equal(env['DSH_HOME'], 'C:\\tmp-home');
  });
});

describe('ACP_COMMAND_ARGS', () => {
  it('与 dsh.cmd 等价：--expose-internals <cli> --profile acp', () => {
    assert.deepEqual(ACP_COMMAND_ARGS('C:\\x\\cli.js'), ['--expose-internals', 'C:\\x\\cli.js', '--profile', 'acp']);
  });
});

describe('discoverDshInstall', () => {
  it('在未安装环境报 HARNESS_NOT_INSTALLED', () => {
    assert.throws(
      () => discoverDshInstall({ env: { PATH: 'C:\\nope', LOCALAPPDATA: 'C:\\nope-appdata' } }),
      (error: unknown) => error instanceof HarnessError && error.code === 'HARNESS_NOT_INSTALLED',
    );
  });

  it('本机安装可被发现（cli 位于 app.asar 内也能通过存在性校验）', (t) => {
    const dshCmd = findDshCmdOnPath(process.env);
    if (dshCmd === null) {
      t.skip('本机 PATH 无 dsh，跳过');
      return;
    }
    const install = discoverDshInstall({ env: process.env });
    assert.ok(install.root.toLowerCase().includes('deepseek harness'));
    assert.ok(install.cli.includes('app.asar'));
    assert.ok(install.exe.endsWith('DeepSeek Harness.exe'));
  });
});
