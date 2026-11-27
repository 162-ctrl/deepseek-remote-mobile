import assert from 'node:assert/strict';
import { test } from 'node:test';

import JSZip from 'jszip';

// M4.9：手机端预览 PDF / Word / Excel / PPT 时，走插件的「电脑读成文字」通道。
// 这里只验证「从 zip 里抽文字」这一步的清洗逻辑（与 lib/index.js 的 extractText 保持一致）。
const xmlToText = (xml) =>
  String(xml)
    .replace(/<w:p[ >]/g, '\n<w:p ')
    .replace(/<a:p[ >]/g, '\n<a:p ')
    .replace(/<\/(w:p|a:p)>/g, '\n')
    .replace(/<[^>]+>/g, '')
    .replace(/[\u0000-\u0008\u000b\u000c\u000e-\u001f]/g, '');

test('docx：把 word/document.xml 抽成保留段落的纯文本', async () => {
  const zip = new JSZip();
  zip.file(
    'word/document.xml',
    '<w:document><w:body><w:p><w:r><w:t>Hello 世界</w:t></w:r></w:p><w:p><w:r><w:t>Second line</w:t></w:r></w:p></w:body></w:document>',
  );
  const buffer = await zip.generateAsync({ type: 'nodebuffer' });
  const loaded = await JSZip.loadAsync(buffer);
  const text = xmlToText(await loaded.files['word/document.xml'].async('string')).trim();
  assert.equal(text.replace(/\n{2,}/g, '\n'), 'Hello 世界\nSecond line');
});

test('pptx：按 slideN.xml 依次抽文字', async () => {
  const zip = new JSZip();
  zip.file('ppt/slides/slide1.xml', '<p:sld><a:p><a:r><a:t>第一页</a:t></a:r></a:p></p:sld>');
  zip.file('ppt/slides/slide2.xml', '<p:sld><a:p><a:r><a:t>第二页</a:t></a:r></a:p></p:sld>');
  const buffer = await zip.generateAsync({ type: 'nodebuffer' });
  const loaded = await JSZip.loadAsync(buffer);
  const names = Object.keys(loaded.files)
    .filter((name) => /^ppt\/slides\/slide\d+\.xml$/.test(name))
    .sort();
  const parts = [];
  for (const name of names) {
    const text = xmlToText(await loaded.files[name].async('string')).trim();
    if (text) parts.push(text);
  }
  assert.deepEqual(parts, ['第一页', '第二页']);
});

test('xlsx：共享字符串表里的文字能被抽出来', async () => {
  const zip = new JSZip();
  zip.file(
    'xl/sharedStrings.xml',
    '<sst><si><t>项目</t></si><si><t>金额</t></si></sst>',
  );
  const buffer = await zip.generateAsync({ type: 'nodebuffer' });
  const loaded = await JSZip.loadAsync(buffer);
  const text = xmlToText(await loaded.files['xl/sharedStrings.xml'].async('string'));
  assert.ok(text.includes('项目'));
  assert.ok(text.includes('金额'));
});
