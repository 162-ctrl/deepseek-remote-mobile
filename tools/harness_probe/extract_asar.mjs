import fs from 'node:fs';
import path from 'node:path';

const asar = 'C:/Users/user/AppData/Local/Programs/DeepSeek Harness/resources/app.asar';
const pkgRoot = asar + '/dsh/node_modules/@deepseek-ai';
const out = 'D:/用户/项目/deepseek手机端/tools/harness_probe/asar_dump';

fs.mkdirSync(out, { recursive: true });

const all = fs.readdirSync(pkgRoot);
console.log('TOTAL_PACKAGES', all.length);
console.log('NAMES', all.join(','));

const want = (n) =>
  n === 'dsh' ||
  /^dsh-(host|client|api|sdk|acp|typert|web|desktop|headless|job|permission|session|workspace|agent)/.test(n);

const copied = [];
for (const name of all) {
  if (!want(name)) continue;
  const src = path.join(pkgRoot, name);
  let st;
  try { st = fs.statSync(src); } catch { continue; }
  if (!st.isDirectory()) continue;
  const dst = path.join(out, name);
  try {
    fs.cpSync(src, dst, {
      recursive: true,
      filter: (s) => {
        const rel = path.relative(src, s).replaceAll('\\', '/');
        if (rel === '') return true;
        // keep lib/, package.json, cordis.patch.yml; skip tests/maps/node_modules
        if (rel.startsWith('node_modules')) return false;
        if (rel.startsWith('lib/') || rel === 'lib') return true;
        if (/\.(json|yml|yaml|md)$/.test(rel) && rel.split('/').length === 1) return true;
        return false;
      },
    });
    copied.push(name);
  } catch (e) {
    console.log('COPY_ERR', name, e.message);
  }
}
console.log('COPIED_COUNT', copied.length);
let bytes = 0;
const walk = (d) => {
  for (const e of fs.readdirSync(d, { withFileTypes: true })) {
    const p = path.join(d, e.name);
    if (e.isDirectory()) walk(p);
    else bytes += fs.statSync(p).size;
  }
};
walk(out);
console.log('DUMP_BYTES', bytes);
console.log('DUMP_PATH', out);
