// M4.74：把 Tailscale 的 100.64/10 地址单独标出来（跨网络时比公网隧道快，也不依赖 cloudflared）。
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { classifyAddress, lanAddresses } from '../lib/server.js';

test('M4.74 100.64/10 认成 tailscale', () => {
  assert.equal(classifyAddress('100.101.102.103'), 'tailscale');
  assert.equal(classifyAddress('100.64.0.1'), 'tailscale');
  assert.equal(classifyAddress('100.127.255.254'), 'tailscale');
});

test('M4.74 100.64/10 之外不算 Tailscale', () => {
  assert.notEqual(classifyAddress('100.128.0.1'), 'tailscale');
  assert.notEqual(classifyAddress('100.63.255.255'), 'tailscale');
});

test('M4.74 普通局域网与虚拟网卡分开', () => {
  assert.equal(classifyAddress('192.168.1.233', 'WLAN'), 'lan');
  assert.equal(classifyAddress('10.0.0.5', '以太网'), 'lan');
  assert.equal(classifyAddress('172.20.0.1', 'vEthernet (WSL)'), 'virtual');
  assert.equal(classifyAddress('192.168.56.1', 'VirtualBox Host-Only Network'), 'virtual');
});

test('M4.74 lanAddresses 带 kind，Tailscale 排最前', () => {
  const list = lanAddresses();
  assert.ok(Array.isArray(list));
  for (const item of list) {
    assert.ok(['tailscale', 'lan', 'virtual'].includes(item.kind), `unexpected kind ${item.kind}`);
    assert.equal(item.virtual, item.kind === 'virtual');
  }
  const kinds = list.map((item) => item.kind);
  if (kinds.includes('tailscale')) {
    assert.equal(kinds[0], 'tailscale', 'Tailscale 应排第一');
  }
});

test('M4.74 配对接口返回 tailscaleUrls，配网页有 Tailscale 那一行', () => {
  const source = readFileSync(new URL('../lib/server.js', import.meta.url), 'utf8');
  assert.match(source, /tailscaleUrls/);
  assert.match(source, /Tailscale（同一 Tailnet，跨网络可用）/);
  assert.match(source, /局域网 · Tailscale · 公网隧道/);
});
