import fs from 'node:fs';
import path from 'node:path';

const asar = 'C:/Users/user/AppData/Local/Programs/DeepSeek Harness/resources/app.asar';
const base = asar + '/dsh/node_modules/@deepseek-ai';
const out = 'D:/涓囨槉鏋?椤圭洰/deepseek鎵嬫満绔?tools/harness_probe/asar_dump';

const KEY = [
  'dsh', 'dsh-cmdline', 'dsh-client-file-upload', 'dsh-attachment-local', 'dsh-tool-cordis',
  'dsh-api-gateway', 'dsh-api-remote-access', 'dsh-api-remotes',
  'dsh-api-session-controller', 'dsh-api-job-controller', 'dsh-api-workspace-controller',
  'dsh-api-workspace-files', 'dsh-api-terminal-controller', 'dsh-api-settings-controller',
  'dsh-client-connection', 'dsh-host-webserver', 'dsh-host-frontend-static',
  'dsh-sdk-app', 'dsh-sdk-jsonrpc-server', 'dsh-sdk-protocol', 'dsh-sdk-minimal',
  'dsh-acp', 'dsh-acp-app', 'dsh-typert-protocol', 'dsh-typert-registry', 'dsh-typert-loader',
  'dsh-web', 'dsh-web-app', 'dsh-desktop-host', 'dsh-user-approval', 'dsh-user-questions',
  'dsh-permission-presets', 'dsh-headless', 'dsh-agent-loop', 'dsh-session-query',
];

fs.mkdirSync(out, { recursive: true });

function copyTree(pkg, rel) {
  const src = rel ? path.join(base, pkg, rel) : path.join(base, pkg);
  const dst = rel ? path.join(out, pkg, rel) : path.join(out, pkg);
  let ents;
  try { ents = fs.readdirSync(src, { withFileTypes: true }); } catch (e) {
    console.log('READDIR_FAIL', pkg, rel, e.code || e.message);
    return 0;
  }
  fs.mkdirSync(dst, { recursive: true });
  let n = 0;
  for (const e of ents) {
    const childRel = rel ? rel + '/' + e.name : e.name;
    if (e.isDirectory()) {
      if (rel === '' && /^(node_modules|test|tests|\$deps)$/.test(e.name)) continue;
      if (rel === 'lib' && e.name === 'node_modules') continue;
      n += copyTree(pkg, childRel);
    } else {
      if (rel === '' && !/\.(json|yml|yaml)$/.test(e.name)) continue;
      if (rel === 'lib' && /\.(map|d\.ts)$/.test(e.name)) continue;
      try {
        const buf = fs.readFileSync(path.join(base, pkg, childRel));
        fs.writeFileSync(path.join(out, pkg, childRel), buf);
        n += 1;
      } catch (e) {
        console.log('READ_FAIL', pkg, childRel, e.code || e.message);
      }
    }
  }
  return n;
}

let total = 0;
for (const pkg of KEY) {
  const c = copyTree(pkg, '') + copyTree(pkg, 'lib');
  console.log('PKG', pkg, c);
  total += c;
}
console.log('FILES', total);

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

