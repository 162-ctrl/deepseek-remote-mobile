# M4.69 报告：扫描件 .docx 按页看图（App 0.4.63+84）

## 一句话
用户那份「没读出文字」的 .docx 其实没有文字——它是 4 张扫描照片；现在文件页在抽不出文字时会把 `word/media/` 里的图片按页显示出来，手机上不装 WPS 也能看。

## 之前的问题
| 现象 | 原因 |
| --- | --- |
| 打开 `示例作业.docx`（5.39 MB）只显示「这份 .docx 里没读出文字」 | 这份文档的 `word/document.xml` 里 `<w:t>` 数量是 0（纯图片），文字抽取必然为空 |
| 点「用其他应用打开」还是失败 | 这台手机没装能处理 `.docx` 的应用，`resolveActivity` 返回 null |
| 只能分享，看不到内容 | 文件页在抽不出文字时只有兜底面板，没有别的显示方式 |

排查依据：磁盘上那份真文件 `D:\Projects\课程\上册\专业课\示例作业\示例作业.docx`，5,648,063 字节，合法 zip（`50 4B 03 04`）、EOCD 在 5648041、21 个条目；`word/document.xml` 是正常 deflate（`csize=1308 / usize=7246`），另有 `word/media/image1..4.jpeg`（最大一张 5,237,656 字节）。用探针跑 `docxTextFromBytes` 得到 `null`、`<w:t>` 计数 0，才确认「没有文字」是文档本身如此。

## 改动
| 文件 | 改动 |
| --- | --- |
| `app/lib/services/office_text.dart` | 把中央目录解析抽成 `_listEntries()`；`readZipEntry` 复用它；新增 `docxImagePages(bytes, {maxPages = 24, maxBytes = 40 MB})`：只取 `word/media/` 下图片扩展名的条目，按文件名数字排序（`image2` 在 `image10` 前面），超出张数/总量截断 |
| `app/lib/screens/file_viewer_screen.dart` | 新增 `_officePages` 状态；`_loadBytes()` 在 docx 抽不出文字时调用 `docxImagePages`；`_buildBinaryBody()` 在图片非空时渲染竖排图片列表（圆角、`BoxFit.fitWidth`、单张失败给「第 N 张图片没法显示」）；`_OfficePreviewFooter` 加 `note` 参数，图片模式说明改成「这份文档没有可选文字（多半是扫描件），上面是文档里的图片」 |
| `app/test/docx_pages_m4_69_test.dart` | 新增 5 例：有文字不当图片文档 / 没文字抽出 media 图片 / 数字顺序 / 张数上限 / 文件页显示图片预览 |

## 验收
- 定向 `flutter test test/docx_pages_m4_69_test.dart` → **5/5**。
- 全量 `flutter test` → **550/550**（545 + 5）。
- `flutter analyze --no-pub` → 33 issues、**0 error**（与 0.4.62 同数）。
- 真文件复核（临时探针，已删）：`pages=4`，尺寸 `[133091, 5236856, 131023, 134833]`，与 `word/media/image1..4.jpeg` 一一对应。
- 反证：把 `docxImagePages` 的 `word/media/` 前缀判断去掉 → 「没文字抽出 media 图片」用例会把 `notes.txt` 也算进去（长度变 3），恢复后 5/5。

## 交付
- App `0.4.63+84`（`0.4.63-m4.63`），APK **74,216,761 字节**，SHA256 `5B6DF297FE4D81E48BDC095A34CE2AB0B2431FBD20E461869A12B8A7CCF04B60`，`versionCode 84`。
- 四处同哈希：构建产物、`dist/DeepSeek-Remote-AI-v0.4.63-m4.63.apk`、`dist/DeepSeek-Remote-latest.apk`、根目录 `DeepSeek Remote AI 手机端 v0.4.63-m4.63.apk`。
- `tools/verify-release.mjs` 四项一致；`/api/v1/app/version` 的 `notes` 自动带上 0.4.63 段。
- `docs/UPDATE_NOTES.md` 与 `app/assets/update_notes.md` 顶部已加 0.4.63 段；电脑端 `received/` 已放入 APK、更新说明与报告。
- 插件未改（仍 0.2.69），无需热载。

## 限制与下一步
- 只按「图片页」显示，不还原 Word 版式、页眉页脚与表格线；纯图片文档没有可选文字，无法复制正文。
- 上限 24 张 / 40 MB，超过的尾部不显示（会少页）。
- `.doc`（老格式，OLE 容器）仍然只能交给外部应用或分享。
- 遗留：M4.62 直播推送帧还没在真机验证；M4.57 接收文件仍待真机验收。
