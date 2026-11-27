# M4.41 删掉「电脑」页，紧急停止搬进「我的」

> 更新：2026-11-20（Asia/Shanghai）
> 交付版本：手机端 `0.4.41+67`（versionName `0.4.41-m4.41`）。插件未改（仍 `0.2.30`）。

## 一句话结论

用户说「可以把这个页面删了」——「电脑」页整页删除，抽屉从四个入口变三个；
那一页唯一不能丢的东西是**紧急停止**，它被搬到了「我的」页（连接时才出现），
滑动 + 二次确认的手感完全没变。

## 为什么不是「直接删掉整页代码」

「电脑」页原来有四处内容，逐条对照后只有一处是独占的：

| 内容 | 别处有没有 | 处置 |
|---|---|---|
| Agent / Harness 版本 | 「我的 → 连接与设备」就有 | 跟着页面删 |
| 当前权限 3 级 + 权限说明弹层 | 只在那一页 | 删（等级本身仍由电脑端配置决定，手机端只是展示） |
| 紧急停止（滑动 + 二次确认） | **只有那一页有** | **搬到「我的」** |
| 未连接时的空态「连接后在这里管理这台电脑」 | 「我的」也有连接入口 | 跟着页面删 |

## 改动

| 文件 | 改了什么 |
|---|---|
| `app/lib/screens/root_shell.dart` | 去掉 `import 'control_screen.dart'`；`IndexedStack` 从 4 个子页收缩到 3 个；`RootShellItems` 去掉「电脑」；`_openProjects` / `_openTasks` 与通知路由 `'tasks'` 的索引从 2 改成 1（工作区现在排第二）；顺手删掉一个从未使用的 `projects_screen.dart` import |
| `app/lib/screens/profile_screen.dart` | 「连接与设备」那组之后新增「紧急停止」块（`if (connected)`）：图标 + 说明 + `SlideToStop`；新增 `_emergencyStop()`，走 `confirmDanger()` → `liveStore.disconnect()` → SnackBar「已断开与电脑的连接」 |
| `app/lib/screens/control_screen.dart` | **整份删除**（401 行） |
| `app/test/widget_test.dart` | 抽屉入口断言从四个改成三个，并新增「抽屉里不能再出现『电脑』」；删掉「电脑页未连接时展示连接空态」 |
| `app/test/empty_state_test.dart` | 删掉「电脑页空态文案」 |
| `app/test/emergency_stop_m4_41_test.dart` | 新增 3 例（见下） |

## 验收证据

`app/test/emergency_stop_m4_41_test.dart` 3 例：

1. 连上电脑时「我的」里能找到 `SlideToStop`，拖到轨道 72% 之后弹「紧急停止远程连接？」，
   **弹窗之前 `disconnects == 0`**，点「确认停止」才变 1 并弹「已断开与电脑的连接」。
2. 没连电脑时看不到紧急停止（`SlideToStop` 与文案都不存在）。
3. `RootShellItems` 只剩 `['AI 助手', '工作区', '我的']` 三项。

全量 `flutter test test/` → **463/463 PASS**（462 − 2 删掉的用例 + 3 新增）。

## 构建与发布

```powershell
robocopy "<项目根>\app" C:\Users\user\dsh-tools\build\dsh-app /E /XD build .dart_tool .gradle .idea .cxx /XF *.iml
cd C:\Users\user\dsh-tools\build\dsh-app; flutter build apk --release
```

- APK **73,032,914 字节**，`versionCode='67'` / `versionName='0.4.41-m4.41'`
- SHA256 `5A87F1DF00E36036BDCD15141F4652900DD444511C1D01BA3C63EA27A5F12A61`
- 三处同哈希：`dist\DeepSeek-Remote-AI-v0.4.41-m4.41.apk`、`dist\DeepSeek-Remote-latest.apk`、
  根目录 `DeepSeek Remote AI 手机端 v0.4.41-m4.41.apk`
- `GET /api/v1/app/version` 回读：`versionCode 67 / 0.4.41-m4.41 / 73032914 / 5a87f1df…5f12a61`

## 限制与下一步

- 权限说明弹层（3 级 · 项目文件 / 高风险操作 / 紧急停止）随页面一起删了；如果还想看，
  可以改成在「我的 → 连接与设备」里点一行展开——说一声就加。
- 抽屉的「历史会话」在插件直连下仍然是空的（走的是 M1.1 旧接口 `GET /api/v1/conversations` → 404），
  这个之前挂在「电脑页」那个三选项里没定，现在电脑页已经删了，只剩「修它」或「删它」两种选择。
- 紧急停止搬过去之后占了一屏空间，如果觉得「我的」太长，可以折叠进「连接与设备」那张卡里。
