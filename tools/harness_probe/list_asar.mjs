import fs from 'node:fs';
const asar = 'C:/Users/user/AppData/Local/Programs/DeepSeek Harness/resources/app.asar';
function ls(p, depth = 0, max = 2) {
  let e;
  try { e = fs.readdirSync(p, { withFileTypes: true }); } catch (err) { console.log('  '.repeat(depth) + 'ERR ' + (err.code || err.message)); return; }
  for (const d of e) {
    console.log('  '.repeat(depth) + (d.isDirectory() ? '[D] ' : '    ') + d.name);
    if (d.isDirectory() && depth < max) ls(p + '/' + d.name, depth + 1, max);
  }
}
console.log('=== app.asar root ===');
ls(asar, 0, 0);
console.log('=== app.asar/dsh ===');
ls(asar + '/dsh', 0, 1);
