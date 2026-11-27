# M4.13 工作区按项目分组 + 新建项目固定落 `D:\Projects\项目`

日期：2026-11-16
版本：App **0.4.13+40**（`0.4.13-m4.13`），插件 **0.2.20**

## 一句话结论

手机「工作区」页从**平铺的会话卡**改成**和电脑端一致的项目卡**：同名目录的会话收进一张可折叠的项目卡里，空目录也占一张卡并标「空项目」；「新建项目」现在固定建在电脑的 `D:\Projects\项目` 下，而不是随便挑一个授权根。

## 起因

用户发来手机「工作区」页截图：

> 按照工作区项目分类，做成和电脑上一样的，可以折叠打开，并且可以新建对话，新的项目区是建立在电脑端"D:/用户/项目"这个文件里面

截图里所有会话（示例项目D、古典诗词鉴赏、计算方法实验、课程设计、deepseek手机端 …）是**一列平铺的存档卡**，同一个目录下的多个会话各占一张，目录多了根本看不出归属。

两轮追问后定下的范围：

| 问题 | 用户的回答 |
| --- | --- |
| 「新建对话」指什么 | **先只做「新建项目」，新建对话以后再说** |
| 新项目建在哪 | **固定建在 `D:\Projects\项目`** |

## 现状与差距

| 项 | M4.12 之前 | M4.13 |
| --- | --- | --- |
| 列表结构 | 任务卡 + `_idleWorkspaces` 空目录卡 + 底部「以前跑过、电脑上已经看不到的会话」存档组，三摊各排各的 | 每个目录一张 `_ProjectGroupCard`，会话（含存档）挂在所属项目下 |
| 同目录多会话 | 各占一张卡 | 收进同一张项目卡 |
| 空目录 | 一张「暂无会话」卡 | 项目卡 + 「空项目」胶囊，点进去仍可新建会话 |
| 折叠 | 无 | 点头部整行折叠/展开（`_collapsed` 记录路径） |
| 新建 | `新建工作区`，落第一个授权根 | `新建项目`，`parentDir` 固定 `D:\Projects\项目` |

## 手机端改动

### 新增 `app/lib/services/project_groups.dart`

不依赖 Flutter 的纯函数，方便单测：

- `class ProjectGroup<T>`：`path` / `name` / `parent` / `items` / `isEmpty`；
- `String projectNameOf(String path)`：取末段目录名；
- `String parentPathOf(String path)`：取父目录（盘符根如 `D:\项目` 返回空串）；
- `List<ProjectGroup<T>> groupWorkspacesByProject<T>({required Iterable<String> paths, required List<T> Function(String) itemsOf, required int Function(T) maxOf, Iterable<String> extraRoots})`：按 `extraRoots ∪ paths` 建组，组内按 `maxOf` 倒序，组间按最近活动倒序。

### 改 `app/lib/screens/tasks_screen.dart`

- 新增 `final Set<String> _collapsed = <String>{};`（折叠的项目路径）与 `List<_ProjectGroup> get _groupRows`（原 `_groups`，与局部变量重名故改名）。
- `build` 里 `final groups = _groupRows;` **必须在 children 列表之前**声明，不能在 `if` 分支里。
- 原来的「`_idleWorkspaces` 卡 + 任务卡 + 存档组」整段换成 `_ProjectGroupCard` 列表；`_idleWorkspaces` 保留但只用于判断。
- `_ProjectGroup`：`path` / `name` / `List<TaskItem> tasks` / `List<ArchivedSession> archived`；`lastTime` 取 `task.lastTime ?? task.updatedAt.millisecondsSinceEpoch`。
- `_ProjectGroupCard`：头部整行可点（`Icons.folder_open_rounded` ↔ `Icons.folder_rounded` 提示展开状态），右侧 chevron 进 `WorkspaceScreen`；展开后列 `_SessionRow`。
- `_SessionRow`：左侧 3×16 竖线按状态着色（等待授权 = `danger` / 运行中 = `accent` / 其他 = `line`）；行尾文字依次是 `等待授权` → `直播中` → `已存档` → 相对时间 → `已完成`。
- **删除** `class _WorkspaceCard`（原 L625-716）。
- 胶囊文案 `新建工作区` → `新建项目`。

### 改 `app/lib/widgets/workspace_create_dialog.dart`

- 新增 `const String kDefaultProjectParent = r'D:\Projects\项目';`
- 标题「新建工作区」→「新建项目」，输入框 label「工作区名称」→「项目名称」。
- `_usesProjectParent`：判断授权根里是否**包含**项目根（本身或其父/子目录），是则 `parentDir: kDefaultProjectParent`，否则 `null`（退回第一个授权根）。
- 提示文案 `将建在：$root\$_preview`；没授权项目根时追加「电脑端没授权 …，先建在第一个授权目录下」。

### 改 `app/lib/services/history_api.dart` / `app/lib/data/live_store.dart`

`createDesktopWorkspace(name, {String? parentDir})` 透传到 `POST /api/v1/desktop/workspaces` 的 `body.parentDir`；`DesktopWorkspaceCreated` 新增 `parent` 字段。

## 插件端（0.2.20，本版内置 M4.13 改动）

- `dsh-plugin-m1/lib/index.js`：
  - `const DEFAULT_PROJECT_PARENT = 'D:\\Projects\\项目';`
  - `resolveParentDir(requested)`：父目录必须是某个授权根本身或子目录（`canonicalPath` 比较 + `wantedKey.startsWith(rootKey + '\\')`）；否则该目录**真实存在**也放行；都不满足退回第一个授权根。`D:\Projects\项目` 本身不在授权根里，但它是现有工作区路径的父目录，所以走「真实存在就放行」这一支。
  - `projectParentPath()` 返回项目根。
  - `createDesktopWorkspace(name, parentDir)`：给了 `parentDir` 就只在该父目录下找已存在子目录，否则退回 `workspaceRootsNow()` 全扫；返回 `{ path, name, parent }`。
  - `listDesktopWorkspaces()` 每行新增 `parent`（`dirname(path)`）与 `isProject`（父目录 == 项目根）。
- `dsh-plugin-m1/lib/server.js:307-330`：`POST /api/v1/desktop/workspaces` 读 `body.parentDir` 并透传。
- 新增 `dsh-plugin-m1/test/workspace-create.test.js` 8 例（`grabFunction` 支持 `const X = async (` 写法）。

## 验收证据

| 项 | 结果 |
| --- | --- |
| App 测试 | `flutter test` **353/353 通过**（M4.12 的 344 + `project_groups_m4_13_test.dart` 7 + `workspace_m4_test.dart` 新增 2） |
| 插件测试 | `node --test "test/*.test.js"` **39/39 通过**（原 31 + 8）；`node --check lib/index.js lib/server.js` 通过 |
| 静态检查 | `flutter analyze` 本机仍不可用（中文路径导致 analysis server 崩 `FormatException: Unterminated string`），以 `flutter test` 全量编译代替 |
| 构建 | release APK **72,589,702 字节**，SHA256 `111DFFA562204C96A6874CF51A9A24266F3C901D4171BBA4654394D1144FDEB0`；aapt2 `versionCode='40' versionName='0.4.13-m4.13'`，minSdk 24 / targetSdk 36 |
| 发布 | `dist\DeepSeek-Remote-AI-v0.4.13-m4.13.apk`、`dist\DeepSeek-Remote-latest.apk`、根目录 `DeepSeek Remote AI 手机端 v0.4.13-m4.13.apk`；`GET /api/v1/app/version` 返回 `versionCode 40 / 0.4.13-m4.13 / size 72589702` |
| 插件安装副本 | `C:\Users\user\.dsh\profiles\desktop\node_modules\dsh-plugin-m1\` 的 `lib/index.js`、`lib/server.js`、`package.json` 与源码树哈希一致，version 0.2.20（`Copy-Item` 报「文件正由另一进程使用」，实际已同步） |
| 真机 | **未复测**（`adb devices` 无设备），分组/折叠/新建由 widget 测试覆盖 |

## 构建命令

```powershell
$env:Path = "C:\Users\user\dsh-tools\flutter\flutter\bin;" + $env:Path
$env:ANDROID_HOME = "C:\Users\user\dsh-tools\android-sdk"
$env:JAVA_HOME   = "C:\Users\user\dsh-tools\jdk\jdk-21.0.12.1+1"   # 注意 JDK 在子目录里

# 中文路径下 AOT 快照会挂（Unable to read file … app.dill），必须先复制到 ASCII 目录
robocopy "<项目根>\app" C:\Users\user\dsh-tools\build\dsh-app `
  /E /XD build .dart_tool .gradle .idea .cxx /XF *.iml
cd C:\Users\user\dsh-tools\build\dsh-app
flutter build apk --release
```

## 限制与下一步候选

1. **插件 0.2.20 仍未被加载**：`GET /api/v1/health` 至今返回 `version: 0.2.19`。必须**完整退出 DSH 再打开**，否则 `parentDir` 不认、`listDesktopWorkspaces` 也没有 `isProject`。App 侧已做兜底（授权根里找不到项目根就退回第一个授权根并提示）。
2. **「新建对话」（在项目里开新会话）本轮未做**——用户明确说以后再说。项目卡里点会话进直播，chevron 进工作区页，都没有「在这个项目里开一个新会话」的入口。
3. `tools\verify-plugin-m4.ps1` 在 PowerShell 5.1 下仍是 15 个 syntax error，本轮没有跑 14/14 自检。
4. 展示态：项目卡头部只显示项目名与「N 个会话」，还没有「最后活动 1 小时前」这类副标题（截图里的官方样子有）。
