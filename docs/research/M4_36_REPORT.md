# M4.36 报告：提问卡的「提交」不再被顶出屏幕

- 版本：`0.4.36+62`（versionName `0.4.36-m4.36`）
- 插件：不变（0.2.30）
- 交付时间：2026-11-18
- 测试：`flutter test` **430/430**

## 一句话结论

M4.35 只修对了一半。用户的原话是「**有通知，只是划不动提交不了**」——通知那条路本来就是通的（前台服务一直在跑），真正卡住的是**「跳过 / 提交」被选项顶到了屏幕外**：卡片整体塞进滚动区，按钮虽然在卡片里，却跟着选项一起滚走。

## 起因

上一轮我按「两个毛病同一个根」处理，把授权卡与提问卡一起塞进一个 55% 屏高的 `SingleChildScrollView`。结果是：**列表能滚了，但按钮也跟着滚**。用户选完答案，手指往下滑找按钮，滑到底才发现按钮在滚动内容的最末尾，或者干脆滑过头。

## 根因

`_QuestionCard` 内部是一整块 `Column`（标题 → 问题 → 选项 → 输入框 → 按钮行），外面被 `SingleChildScrollView` 包住意味着**整块都在滚**。要让按钮固定，必须让「滚动的只有选项区」，也就是滚动容器要下沉到卡片内部，而不是包在卡片外面。

另外父层用的是 `Flexible`（默认 `FlexFit.tight`），卡片被拉满到上限 55%——一个问题的短卡片也白占半屏。

## 改了什么

| 位置 | 改动 |
|---|---|
| `app/lib/screens/desktop_session_screen.dart` 的 `_QuestionCard` | 根 `Container > Column(mainAxisSize: MainAxisSize.min)`：标题行是固定子项；中间「问题 + 选项 + 输入框」包 `Flexible(fit: FlexFit.loose, child: SingleChildScrollView(child: Column(...)))`；底部「跳过 / 提交」`Row` 也是固定子项 |
| 同上，父层 | `ConstrainedBox(maxHeight: 屏高 55%) > Padding > Column(mainAxisSize: min)`，提问卡外面改成 `Flexible(fit: FlexFit.loose, child: Padding(bottom: 8, child: _QuestionCard(...)))`——卡片按内容高度自适应，只有超出上限才在卡内滚 |

效果：标题不动、按钮不动，只有选项列表在中间那段滚动；短卡片（一个问题两个选项）不再占半屏。

## 验收证据

| 项 | 结果 |
|---|---|
| `app/test/desktop_question_scroll_m4_35_test.dart` 第二例 | 钉三件事：①`find.widgetWithText(FilledButton, '提交')` 一开始就 `hitTestable`；②最后一个选项一开始看不到；③在卡内把选项往上拖 420 像素后，最后那个选项可见、`提交` 仍然可点 |
| 反证（上限放大到屏高 1.2 倍） | 列表高度 `Actual: <0.0>`，且 `Found 0 widgets with type "FilledButton"` —— 正是用户遇到的「提交不了」 |
| 全量 | `flutter test test/` → **430/430 PASS** |
| 老用例 | `desktop_question_m4_23_test.dart`（2 例）、`desktop_live_m4_14_test.dart`（源码断言）继续通过 → 短卡片与原交互没被改坏 |

## 构建

```
robocopy "<项目根>\app" "C:\Users\user\dsh-tools\build\dsh-app" /E /XD build .dart_tool .gradle .idea .cxx /XF *.iml
cd C:\Users\user\dsh-tools\build\dsh-app
flutter build apk --release
```

- APK：**73,049,346 字节**，versionCode **62**，SHA256 `13F0D3AF69E6B7247A8B7F65E659E93E4F23E242A9479BAF95D6BAFA24E349A3`
- 三处同哈希：`dist\DeepSeek-Remote-AI-v0.4.36-m4.36.apk`、`dist\DeepSeek-Remote-latest.apk`、根目录 `DeepSeek Remote AI 手机端 v0.4.36-m4.36.apk`
- `/api/v1/app/version` 回读：`versionCode 62 / 0.4.36-m4.36 / 73,049,346 / 13f0d3af…`

> 字节数与 0.4.35 完全相同（73,049,346），是巧合——两次都是同一套依赖、同样的压缩率；用 `versionCode` 与 SHA256 区分，不用大小。

## 限制与下一步

- 选项超过 6 个时要在卡内滚比较远，没有折叠或分页。
- 提交后到卡片消失之间是「发送中…」，按钮置灰但无进度。
- 卡片区上限是硬编码的「屏高 55%」，横屏与小屏没有单独适配。
- 真·锁屏推送仍未做（通知依赖工作区页那颗 5 秒轮询 + 前台服务常驻）。
- 待用户定的两件事：抽屉「历史会话」在插件直连下永远是空的（M1.1 旧接口 404）；「电脑」页是修强还是删掉只留紧急停止。
