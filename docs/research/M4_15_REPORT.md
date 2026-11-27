# M4.15 新建项目落点修对：不再退回「第一个授权目录」

## 一句话结论

M4.13 的「新建项目」把落点判断写成「电脑端授权根里有没有 `D:\Projects\项目` 这一项」，
而电脑端返回的授权根恰好是**项目本身**（`…\项目\deepseek手机端`、`…\项目\示例项目D`），
`…\项目` 从来不在列表里 —— 于是每次都判成「没授权」，退回第一个授权根。手机上因此
看到「将建在：D:\Projects\课程\上册\计算方法实验」。现在手机端**无条件指名**项目根，
插件侧本来就允许「显式指定且目录真实存在」，一行判断的删除就修好了。

## 起因

用户 16:14 发来截图：新建对话框标题「新建工作区」、输入框 label「工作区名称」、
提示「将建在: D:\Projects\课程\上册\计算方法实验」，反馈「新项目要建立的位置不对」。

截图同时暴露两件事，必须分开算：

| 现象 | 真实原因 | 归属 |
| --- | --- | --- |
| 标题仍是「新建工作区」、label 仍是「工作区名称」 | 手机上装的还是 M4.13 之前的旧 APK（M4.13 已把文案改成「新建项目 / 项目名称」） | 只需重装 |
| 「将建在：…\计算方法实验」 | 手机端 M4.13 的落点判断逻辑本身写错 | 代码要改 |

所以「装新版就好」这个结论是错的 —— 新版照样会落错。

## 根因

`app/lib/widgets/workspace_create_dialog.dart`（M4.13 版本）里有：

```dart
bool get _usesProjectParent {
  final roots = widget.liveStore.workspaceRoots;
  for (final root in roots) {
    if (root.replaceAll('/', r'\').toLowerCase() ==
        kDefaultProjectParent.toLowerCase()) {
      return true;
    }
  }
  return false;
}
```

`createDesktopWorkspace(name, parentDir: _usesProjectParent ? kDefaultProjectParent : null)`。

`liveStore.workspaceRoots` 来自 `GET /api/v1/desktop/workspaces`，实测 9 条全是具体项目：

```
<项目根>      D:\Projects\示例项目B
D:\Projects\示例项目D            D:\Projects\示例项目C
D:\Projects\课程\上册\专业课   D:\Projects\课程\上册\古典诗词鉴赏
D:\Projects\课程\上册\计算方法实验   D:\Projects\课程\上册\数据结构实验
D:\Projects\课程\上册\面向对象程序设计\课程设计
```

`D:\Projects\项目` 是它们的**父目录**，从来不是其中一项 → `_usesProjectParent == false`
→ `parentDir: null` → 插件 `resolveParentDir(null)` 走「退回第一个授权根」分支
（本例第一个根是 `…\计算方法实验`，正是截图里的落点）。

## 改动

### 手机端

`app/lib/widgets/workspace_create_dialog.dart`：

- 删掉 `_rootHint` 与 `_usesProjectParent` 两个 getter（它们都是「先看授权根里有没有」的思路）。
- 新增 `String get _targetParent`：返回 `kDefaultProjectParent`（去掉尾部反斜杠），注释写明为什么不能再依赖授权根。
- `_submit` 里改成无条件 `parentDir: _targetParent`。
- 提示文案统一成 `'将建在：$_targetParent\\$_preview'`（全角冒号，与截图里的旧文案区分），
  删掉「电脑端还没授权根目录，暂时无法新建」与「先建在第一个授权目录下」两个分支 —— 它们描述的分支已经不存在了。

插件端**一行都没改**：现场实测 `POST /api/v1/desktop/workspaces`
`{"name":"m4-14-probe-161524","parentDir":"D:\\Projects\\项目"}` →
`{"ok":true,"path":"D:\\Projects\\m4-14-probe-161524","parent":"D:\\Projects\\项目"}`，
与 `D:\Projects\` 下真实出现的目录一致，`…\计算方法实验\m4-14-probe-161524` 不存在。
探针目录事后已删除。插件 0.2.21 的 `resolveParentDir()` 早就是「显式指定且目录真实存在就放行」，
M4.13 只需要把 `parentDir` 传对。

### 测试

`app/test/workspace_m4_test.dart` 的「成功创建后关闭并返回结果」原本断言落点跟随授权根
（`find.textContaining(r'D:\work')`、`result?.path == r'D:\work\新项目'`），现在改成断死项目根：

```dart
expect(find.textContaining(kDefaultProjectParent), findsOneWidget);
expect(store.parents, <String?>[kDefaultProjectParent]);
expect(result?.path, '$kDefaultProjectParent\\新项目');
```

这条用例的 fake store 只授权了 `D:\work`，正好是「授权根里没有项目根」的真实场景 ——
修好后它必须仍然指向 `D:\Projects\项目`，这就是回归保护。

## 验收证据

| 项 | 结果 |
| --- | --- |
| `flutter test test/workspace_m4_test.dart` | 14/14 PASS |
| `flutter test test/`（全量） | **356/356 PASS** |
| 插件 `node --test "test/*.test.js"` | 46/46 PASS（M4.14 时已验，本次未改插件） |
| 产物字节数 | 72,589,702 |
| SHA256 | `3AA815BE6D58D4C1AC21C7FFAB8CA8E7A12DC475BE72DBC9B79142B64FD2B023` |
| aapt2 badging | `versionCode='42' versionName='0.4.15-m4.15'`，minSdk 24 / targetSdk 36 |
| 三处发布哈希 | `dist\DeepSeek-Remote-AI-v0.4.15-m4.15.apk`、`dist\DeepSeek-Remote-latest.apk`、根目录 `DeepSeek Remote AI 手机端 v0.4.15-m4.15.apk` 全部 `3AA815BE6D58D4C1` |
| `GET /api/v1/app/version` | `{"versionCode":42,"versionName":"0.4.15-m4.15","size":72589702,"sha256":"3aa815be…","publishedAt":"2026-11-16T08:23:39.274Z"}` |
| `GET /api/v1/health` | `{"status":"ok","version":"0.2.21","agentOnline":true,"apps":2,"publicUrl":"https://<公网隧道>.trycloudflare.com"}` |

## 构建命令

```powershell
$env:Path = "C:\Users\user\dsh-tools\flutter\flutter\bin;" + $env:Path
$env:JAVA_HOME = "C:\Users\user\dsh-tools\jdk\jdk-21.0.12.1+1"   # 不是 ...\jdk，是它下面的子目录
$env:ANDROID_HOME = "C:\Users\user\dsh-tools\android-sdk"

# 中文路径下 AOT 快照会挂（Unable to read file … app.dill），先复制到 ASCII 目录
robocopy "<项目根>\app" C:\Users\user\dsh-tools\build\dsh-app `
  /E /XD build .dart_tool .gradle .idea .cxx /XF *.iml
# robocopy exit=1 表示「已复制文件」，是成功

cd C:\Users\user\dsh-tools\build\dsh-app
flutter build apk --release
```

## 限制与下一步候选

- **手机要重装 0.4.15 并重新配对**：cloudflared 是快速隧道，域名每次重启都变
  （当前 `https://<公网隧道>.trycloudflare.com`），旧域名已死。
  配对码见 `GET /api/v1/pair/info`。长期方案是给插件配固定 `config.publicUrl`。
- 截图里的旧文案（「新建工作区 / 工作区名称」）说明手机端版本落后；建议手机上的
  「设置 → 关于」直接显示 versionCode，便于一眼核对。
- 真机锁屏/后台的授权提醒仍未做：M4.14 只做到「标题栏常驻待应答 N + 接管窗口放宽到 10 分钟」，
  手机 App 退到后台后轮询停止，超时仍会退回电脑（现在有日志）。
- `tools\verify-plugin-m4.ps1` 在 Windows PowerShell 5.1 下仍解析报 15 个 syntax error，未重写。
- 「在项目里新建会话」仍是 M4.13 时用户明确说的「以后再说」。
