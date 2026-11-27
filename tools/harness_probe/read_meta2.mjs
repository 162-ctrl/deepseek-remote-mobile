import fs from 'node:fs';
const asar = 'C:/Users/user/AppData/Local/Programs/DeepSeek Harness/resources/app.asar';
const j = JSON.parse(fs.readFileSync(asar + '/dsh/desktop-runtime.json', 'utf8'));
console.log('TOP_KEYS', Object.keys(j));
for (const k of Object.keys(j)) {
  if (k === 'sharedPackages') { console.log('sharedPackages', j[k].length); continue; }
  console.log('---', k, '---');
  console.log(JSON.stringify(j[k], null, 1).slice(0, 3000));
}
console.log('=== dsh pkg ===');
console.log(fs.readFileSync(asar + '/dsh/node_modules/@deepseek-ai/dsh/package.json', 'utf8'));
function ls(p, depth = 0, max = 2) {
  let e;
  try { e = fs.readdirSync(p, { withFileTypes: true }); } catch (err) { console.log('ERR ' + p + ' ' + (err.code || err.message)); return; }
  for (const d of e) {
    console.log('  '.repeat(depth) + (d.isDirectory() ? '[D] ' : '    ') + d.name);
    if (d.isDirectory() && depth < max) ls(p + '/' + d.name, depth + 1, max);
  }
}
console.log('=== dsh-base ===');
ls(asar + '/dsh/node_modules/@deepseek-ai/dsh-base', 0, 1);
