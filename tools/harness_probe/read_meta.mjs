import fs from 'node:fs';
const asar = 'C:/Users/user/AppData/Local/Programs/DeepSeek Harness/resources/app.asar';
console.log(fs.readFileSync(asar + '/dsh/desktop-runtime.json', 'utf8').slice(0, 4000));
console.log('=== dsh pkg ===');
console.log(fs.readFileSync(asar + '/dsh/node_modules/@deepseek-ai/dsh/package.json', 'utf8'));
console.log('=== dsh-base tree ===');
function ls(p, depth = 0, max = 2) {
  let e;
  try { e = fs.readdirSync(p, { withFileTypes: true }); } catch (err) { console.log('ERR ' + p + ' ' + (err.code || err.message)); return; }
  for (const d of e) {
    console.log('  '.repeat(depth) + (d.isDirectory() ? '[D] ' : '    ') + d.name);
    if (d.isDirectory() && depth < max) ls(p + '/' + d.name, depth + 1, max);
  }
}
ls(asar + '/dsh/node_modules/@deepseek-ai/dsh-base', 0, 1);
