# M4.52 报告：手机没有 WPS 也能读 .docx 正文

**一句话结论**：文件页遇到 `.docx` 不再只能甩给外部应用——App 自己在手机里把 zip 解开、读 `word/document.xml` 抽文字，直接显示成可选中、可滚动的正文；排版、图片、表格线不显示，抽不出文字时说明原因并保留「用其他应用打开」。

---

## 1. 之前的问题

用户发来截图（2026-11-24 08:00）：在工作区里打开 `示例文档.docx`，页面只有一块兜底面板——

> 用其他应用打开
> PDF / Office 文档不让 App 里直接看，交给手机上的 WPS 或系统阅读器打开最清楚。

点按钮后底下一句 toast：

> 手机上没有能打开这种文件的应用，可以先用「复制」或分享

也就是这台手机没装 WPS / 任何能处理 `.docx` 的应用，于是这份 38.6 KB 的文档在 App 里彻底读不到：App 不预览、外部也没人接。

旧实现的三处硬伤：

| 位置 | 行为 | 问题 |
|---|---|---|
| `app/lib/screens/file_viewer_screen.dart:22 previewKindOf()` | `doc/docx/xls/xlsx/ppt/pptx/csv/tsv` 全归 `FilePreviewKind.office` | 一律当二进制，直接放弃预览 |
| 同文件 `_buildBinaryBody()` | Office 走 `_BinaryFallback`（固定文案 + 「用其他应用打开」） | 没装阅读器时没有任何出路 |
| `app/lib/services/file_opener.dart` | `MissingPluginException` 和所有 `PlatformException` 一律吞成 `false` | 「没装应用（`NO_APP`）」与「打开失败（`OPEN_FAILED`）」在 UI 上是同一句话 |

想补上这一格，就得在手机上自己解 Office 容器。`.docx` 是 zip，正文在 `word/document.xml`，抽出纯文字不需要任何第三方库。

## 2. 改动

| 文件 | 改动 |
|---|---|
| `app/lib/services/office_text.dart`（新增） | 纯 Dart 的最小 zip 读取 + docx 正文抽取：`readZipEntry()` 从尾部扫 EOCD（`0x06054b50`）拿中央目录、按 UTF-8 文件名比对、再读本地头（`0x04034b50`），`stored` 直接取、`deflate` 用 `ZLibDecoder(raw: true)` 解；`docxTextFromBytes()` 取 `word/document.xml` → UTF-8 解码 → `docxXmlToText()`；`docxXmlToText()` 把 `<w:tab/>` 转制表、`<w:br/>`/`<w:cr/>`/`</w:p>`/`</w:tr>` 转换行、`</w:tc>` 转制表，剥掉其余标签，还原 `&amp;`/`&lt;`/`&gt;`/`&quot;`/`&apos;` 与 `&#x`/`&#` 实体，压掉多余空行；`isDocxFileName()` 只认 `.docx`（排除 `.docm` 与 `x.docx.zip` 这类伪装）；zip64 一律返回 null，不硬撑 |
| `app/lib/screens/file_viewer_screen.dart` | State 增 `String? _officePreview` 与 `_maxDocxBytes = 12MB`（超过不在主线程解）；`_loadBytes()` 在下载完字节后顺手抽正文；`_buildBinaryBody()` 先判 `_officePreview != null` → 顶部 `_BinaryMetaBar('… · 按文字预览（排版和图片不显示）')` + `SelectableText`（14/1.7）+ 新 `_OfficePreviewFooter`（左侧说明文字怎么来的，右侧仍能「用其他应用打开」）；docx 抽取失败时把兜底文案换成「这份 .docx 里没读出文字（可能加密或不是标准格式），交给手机上的 WPS 打开试试。」 |
| `app/test/office_text_m4_52_test.dart`（新增） | 8 例：stored/deflate 两种压缩的 zip 都能取到 `document.xml`；没有该条目或不是 zip 返回 null；XML→文字（制表 / 换行 / 实体）；超长截断追加「先显示到这里」；`isDocxFileName` 的边界；文件页显示「按文字预览」+ 正文 + 仍能调起外部应用（MIME 正确）；坏 docx 显示「没读出文字」 |
| `app/pubspec.yaml`、`app/lib/app_version.dart`、`android/app/build.gradle.kts`、`android/local.properties` | 版本 → `0.4.52+77` / `0.4.52-m4.52` |
| `app/test/theme_m2_3_test.dart`、`app/test/empty_state_test.dart`、`app/test/widget_test.dart` | 版本断言与「手机端 v0.4.52-m4.52」同步 |

设计取舍：

- **不新增依赖**。zip 只用 `dart:io` 的 `ZLibDecoder`（Android 上可用），XML 用正则剥标签——文档正文是纯文本，够用且好测。
- **只在文件页做文字预览，不做排版还原**。要还原字体、图片、表格线等于自己实现一个 Word 渲染器，收益远小于成本；正文能读、能选中复制，已经解决了「在一台没有 WPS 的手机上读一眼文档」。
- **12MB 上限**。抽正文是同步 CPU 工作，放在 `_loadBytes()` 里做；超大文件（比如带大量图片的 docx）会卡住一帧，所以直接跳过，退回原来的外部应用路径。
- **抽不出文字不装成功**。加密 docx、老式 `.doc`（二进制格式，不是 zip）、改名的 zip 都会走到「没读出文字」，文案说明原因并仍可交给外部应用——不拿空白页骗人。

## 3. 验收

| 项 | 结果 |
|---|---|
| 新增用例 | `app/test/office_text_m4_52_test.dart` **8/8** |
| 反证 | 把 `final officePreview = isDocxFileName(_title) && …` 改成 `false && …` → 文件页那例失败（`+6 -1`，「按文字预览」找不到）；恢复后 8/8 |
| 全量测试 | `flutter test` **527/527 通过**（M4.51 的 519 + 新增 8） |
| 静态检查 | `flutter analyze --no-pub` **32 issues、0 error**（与 M4.51 同数，无新增；未触碰的既有告警仍在，留待第三阶段清） |
| 边界覆盖 | 非 zip / 缺 `document.xml` / stored / deflate / 超长截断 / `.doc`、`x.docx.zip`、`x.docx.bak` 不被误认 |

## 4. 交付

| 项 | 值 |
|---|---|
| App 版本 | **0.4.52+77**（`versionName=0.4.52-m4.52`） |
| APK | `dist/DeepSeek-Remote-latest.apk`，**73,230,270 字节** |
| SHA256 | `B1E53C95BA3BEDE01E6DF11288453FDD4DFD20493200082EB54CBF2665358F67` |
| 同哈希三处 | 构建产物、`dist/DeepSeek-Remote-AI-v0.4.52-m4.52.apk`、根目录 `DeepSeek Remote AI 手机端 v0.4.52-m4.52.apk` |
| 签名 | `C=US, O=Android, CN=Android Debug`（与已装版本同一 debug 密钥，可直接覆盖升级） |
| aapt2 | `versionCode='77' versionName='0.4.52-m4.52'`，applicationId `com.deepseek.remote.deepseek_remote_app` |
| 发布校验 | `node tools/verify-release.mjs --apk dist/DeepSeek-Remote-latest.apk --base http://127.0.0.1:8787 --aapt2 …\build-tools\36.0.0\aapt2.exe` → **四项一致**（本地包信息、size/sha256、已发布版本、versionName） |
| 接口回读 | `GET /api/v1/app/version` → versionCode 77、`0.4.52-m4.52`、size 73230270、sha256 `b1e53c95…`、`publishedAt 2026-11-24T00:57:19.287Z` |

## 5. 限制与下一步

- **不支持 `.doc`（97-2003 二进制格式）**，也不支持 `.xlsx` / `.pptx` 在 App 内预览——它们仍走「用其他应用打开」。要做的话，xlsx 可以抽 `xl/sharedStrings.xml` 拼表格、pptx 可以抽每页 `<a:t>`，容器读取部分能直接复用 `readZipEntry()`。
- **排版不显示**：字体、字号、颜色、图片、表格线、页眉页脚都没有，只有文字与段落/制表位。适合「读一眼内容」，不适合校对版式。
- **仍保留外部应用出口**：抽出的正文底下有「用其他应用打开」，装了 WPS 的用户还能看到真正的版式。
- **失败提示仍统一**：`FileOpener` 把 `NO_APP` 与 `OPEN_FAILED` 都吞成 `false`，所以「没装应用」和「打开失败」还是同一句话。要分清得改 Kotlin 桥 + 网关返回值，留待后续。
- 遗留不变：工作区二级页的「已连接但 Agent 掉线」文案（M4.49）、电脑端看不到手机新建会话的架构问题（M4.50）、第三阶段拆 `LiveStore` / `desktop_session_screen.dart` / `assistant_screen.dart` 与清死代码告警。
