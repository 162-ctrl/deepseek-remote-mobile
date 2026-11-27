// M4.18：插件市场与电脑端同步的回归测试。
//
// 背景：手机「插件市场」以前只读 Host `pluginMarket.listIndexes()`（电脑端
// 「设置 → 插件市场」里手配的第三方索引）。这台电脑一个索引都没配，手机上
// 就永远是空的，而电脑端自己的市场有四十多个可安装的插件包。现在改成直接读
// `pluginManager.listBundles()`，这里断言：
//   1. 多语言 meta 的三种形状都能取到人话（平铺 / 按语言分键 / 直接是字符串）；
//   2. 目录条目带上了安装要用的 spec（包名@精确版本），只给包名会让电脑端重解析版本；
//   3. 没有 meta 时退回 bundle.description，没有名字的条目被剔掉；
//   4. pluginManager 不可用时明确返回 supported:false，手机端才能给出「暂不可用」。
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const source = readFileSync(join(here, '..', 'lib', 'index.js'), 'utf8');

/** 截出 `function name(...) { ... }`（花括号配平）。 */
const grabFunction = (name) => {
  const start = source.indexOf(`\nfunction ${name}(`);
  assert.ok(start >= 0, `找不到函数 ${name}`);
  let depth = 0;
  let begun = false;
  for (let i = start + 1; i < source.length; i += 1) {
    const ch = source[i];
    if (ch === '{') {
      depth += 1;
      begun = true;
    } else if (ch === '}') {
      depth -= 1;
      if (begun && depth === 0) return source.slice(start + 1, i + 1);
    }
  }
  throw new Error(`函数 ${name} 花括号不配平`);
};

/** 截出对象字面量里的箭头函数 `name: async (...) => { ... }`（表达式形式）。 */
const grabArrow = (name) => {
  const at = source.indexOf(`${name}: async (`);
  assert.ok(at >= 0, `找不到箭头函数 ${name}`);
  const arrow = source.indexOf('=>', at);
  assert.ok(arrow > at, `${name} 缺少 =>`);
  let depth = 0;
  let begun = false;
  for (let i = arrow; i < source.length; i += 1) {
    const ch = source[i];
    if (ch === '{') {
      depth += 1;
      begun = true;
    } else if (ch === '}') {
      depth -= 1;
      if (begun && depth === 0) return source.slice(at + name.length + 2, i + 1);
    }
  }
  throw new Error(`箭头函数 ${name} 花括号不配平`);
};

const localizedSrc = grabFunction('localizedMetaText');
const catalogSrc = grabArrow('pluginCatalog');
const asArraySrc = grabFunction('asArray');

assert.match(catalogSrc, /listBundles\(/);
assert.match(catalogSrc, /installTarget/);
assert.match(catalogSrc, /localizedMetaText\(meta, 'name', language\)/);

const buildCatalog = () => {
  const code = `
${asArraySrc}
${localizedSrc}
const catalog = ${catalogSrc};
return catalog;
`;
  // pluginCatalog 是 `apply(ctx)` 里的对象方法，闭包捕获 `ctx`；这里用形参补上。
  return (ctx) => new Function('ctx', code)(ctx);
};

const localizedMetaText = new Function(
  `${localizedSrc}\nreturn localizedMetaText;`,
)();

test('多语言 meta：平铺对象按字段取', () => {
  assert.equal(localizedMetaText({ name: '插件 A', description: '说明 B' }, 'name', 'zh-CN'), '插件 A');
  assert.equal(localizedMetaText({ name: '插件 A', description: '说明 B' }, 'description', 'en'), '说明 B');
});

test('多语言 meta：按语言分键时优先当前语言，取不到退到中文再退英文', () => {
  const meta = { 'zh-CN': { name: '中文名' }, en: { name: 'English name' } };
  assert.equal(localizedMetaText(meta, 'name', 'zh-CN'), '中文名');
  assert.equal(localizedMetaText(meta, 'name', 'en-US'), 'English name');
  assert.equal(localizedMetaText(meta, 'name', 'fr'), '中文名');
});

test('多语言 meta：语言键上直接是字符串也能用；没有 meta 返回空串', () => {
  assert.equal(localizedMetaText({ 'zh-CN': '中文直写' }, 'name', 'zh-CN'), '中文直写');
  assert.equal(localizedMetaText(null, 'name', 'zh-CN'), '');
  assert.equal(localizedMetaText({}, 'name', 'zh-CN'), '');
});

test('pluginCatalog：映射出安装用的 spec 与中文标题', async () => {
  const ctx = {
    get(name) {
      assert.equal(name, 'pluginManager');
      return {
        async listBundles() {
          return [
            {
              name: '@deepseek-ai/dsh-demo',
              official: true,
              availability: 'installation',
              installTarget: { spec: '@deepseek-ai/dsh-demo@0.2.2-rc.1', version: '0.2.2-rc.1' },
              meta: { 'zh-CN': { name: '示例插件', description: '说明文字' } },
              description: 'raw description',
              installed: false,
              enabled: false,
              optional: true,
              removable: true,
              updatable: true,
              listedByDefault: true,
              source: 'official',
            },
          ];
        },
      };
    },
  };
  const data = await buildCatalog()(ctx)({});
  assert.equal(data.supported, true);
  assert.equal(data.language, 'zh-CN');
  assert.equal(data.bundles.length, 1);
  const row = data.bundles[0];
  assert.equal(row.name, '@deepseek-ai/dsh-demo');
  assert.equal(row.title, '示例插件');
  assert.equal(row.description, '说明文字');
  assert.equal(row.spec, '@deepseek-ai/dsh-demo@0.2.2-rc.1');
  assert.equal(row.version, '0.2.2-rc.1');
  assert.equal(row.official, true);
  assert.equal(row.availability, 'installation');
  assert.equal(row.installed, false);
});

test('pluginCatalog：没有 meta 退回 description，没名字的条目被剔除', async () => {
  const ctx = {
    get: () => ({
      async listBundles() {
        return [
          { name: 'plain-bundle', description: '只有说明', installed: true, enabled: true },
          { name: '', description: '没有名字' },
        ];
      },
    }),
  };
  const data = await buildCatalog()(ctx)({});
  assert.equal(data.bundles.length, 1);
  assert.equal(data.bundles[0].title, '');
  assert.equal(data.bundles[0].description, '只有说明');
  assert.equal(data.bundles[0].spec, 'plain-bundle');
  assert.equal(data.bundles[0].installed, true);
});

test('pluginCatalog：pluginManager 不可用时返回 supported:false', async () => {
  const data = await buildCatalog()({ get: () => undefined })({});
  assert.deepEqual(data, { supported: false, bundles: [] });
});
