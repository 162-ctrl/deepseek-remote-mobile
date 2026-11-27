# M4.45 新建的工作区让电脑认下来 + 换签名导致的安装冲突

> 日期：2026-11-23
> 插件 0.2.33 · App `0.4.45-m4.45`（versionCode 71）

## 一句话结论

手机「新建项目」以前只在磁盘上建了目录，**没告诉 DSH 的工作区注册表**，所以电脑那边的列表里看不到；这一轮改成「建目录 + 注册」，并顺手解决了上一版换成 release 签名后手机**装不上**的问题（先用 debug 签名出包，让已装的老版本能直接覆盖升级）。

## 两个问题

### ① 新建的工作区电脑上不显示

- 现场：手机点「新建项目」→ 电脑端 DSH 的工作区/会话列表里没有这个目录。
- 根因：`dsh-plugin-m1/lib/index.js` 的 `createDesktopWorkspace(name, parentDir)` 只做了 `mkdirSync(target)`。DSH 的工作区列表不是扫盘得来的，而是 `workspaceRegistry` 服务里的持久化列表（asar 里的 `class WorkspaceRegistry extends Service`，`async create(path, title)` 会 `realpathNormalize` 再把新条目**前插**到顺序里）。
- 所以磁盘上有目录 ≠ 电脑认识这个工作区。这也是为什么以前「工作区」都是电脑端先建好、手机只是列出来的原因。

### ② 手机上装不上（软件包与现有软件包存在冲突）

- 现场：「安装包的开发者签名有异常」「软件包与现有软件包存在冲突」。
- 根因：M4.44 换了独立 release keystore（`CN=DeepSeek Remote`），而手机里装的历史版本都是 Flutter 默认的 **debug 签名**（`CN=Android Debug`）。Android 不允许用不同签名覆盖安装同一个 `applicationId`——只能卸载重装，而卸载会把手机本地的对话记录和配对信息一起清掉。
- 这是我的改动带来的副作用，得在「正式签名」和「用户数据不丢」之间做一次取舍。

## 改了什么

| 位置 | 改动 |
|---|---|
| `dsh-plugin-m1/lib/index.js` | 新增 `registerDesktopWorkspace(workspacePath, title)`：`ctx.get('workspaceRegistry')` → `registry.create(path, title)`，取不到（老 DSH）返回 `false`，抛错也只记日志不打断建目录 |
| 同上 | `createDesktopWorkspace` 的两个返回分支都先注册再返回，返回值多一个 `registered`；复用已存在目录时也补一次注册（幂等） |
| `app/android/app/build.gradle.kts` | `key.properties` 里 `useDebugSigning=true` 时 release 构建仍用 debug 签名；没有这个开关且存在 key.properties 时用正式签名 |
| `app/android/key.properties` | 本轮写入 `useDebugSigning=true`（让 0.4.45 能覆盖升级已装的 0.4.44 之前版本） |
| `dsh-plugin-m1/test/workspace-create.test.js` | 模板里注入 `log` / `ctx.get('workspaceRegistry')` 桩，新增 3 例：新建后注册、复用目录也注册、注册失败不挡建目录但留日志 | 
| `app/pubspec.yaml`、`app/android/local.properties`、`app/android/app/build.gradle.kts`、`app/lib/app_version.dart`、三个版本断言测试 | 版本 → `0.4.45+71` / `0.4.45-m4.45` |

## 验收

- 插件 `node --test "test/*.test.js"` → **146/146 pass**（基线 143，+3）
- App `flutter test test/` → **497/497 pass**
- 端到端：装好后点「新建项目 → 同名」会对已存在的目录补一次注册（幂等，不会重复建目录），电脑端随之出现；新建的则直接出现
- APK：**73,181,078 字节**，SHA256 `744CE8CEF4237739D203FCF62C4D8C48A6497B1AB0CB321B580469565BAD4901`，`versionCode=71`，`versionName=0.4.45-m4.45`
- 签名：`apksigner verify --print-certs` → `C=US, O=Android, CN=Android Debug`（与手机里已装版本**同签名**，可直接覆盖安装）
- 发布：`dist\DeepSeek-Remote-AI-v0.4.45-m4.45.apk`、`dist\DeepSeek-Remote-latest.apk`、根目录同名三处同哈希；`/api/v1/app/version` 回读一致；`node tools/verify-release.mjs` 四项全绿

## 构建命令

```powershell
robocopy "<项目根>\app" "C:\Users\user\dsh-tools\build\dsh-app" /E /XD build .dart_tool .gradle .idea .cxx /XF *.iml
cd C:\Users\user\dsh-tools\build\dsh-app
flutter build apk --release
```

环境：`JAVA_HOME=C:\Users\user\dsh-tools\jdk\jdk-21.0.12.1+1`、`ANDROID_HOME=C:\Users\user\dsh-tools\android-sdk`。

## 限制与下一步

- 现在这版是**debug 签名**。想切成正式签名（`CN=DeepSeek Remote`），需要：先用当前这版把手机里的数据用起来/备份，然后**卸载一次**、装正式签名包；之后每次升级都不会再有冲突。切换命令：把 `app/android/key.properties` 里的 `useDebugSigning=true` 删掉再构建。
- 注册失败时手机照旧会显示「已建好」，但电脑端可能仍看不到——这种情况下插件日志里有「工作区注册失败（路径）：原因」，下一步要在手机端把 `registered=false` 如实显示出来。
- 历史遗留：旧 state 目录 `<DSH 数据目录>\dsh-plugin-m1.hold\tokens.json`（62,518 B）被 ACL 锁死，需要管理员 `takeown` 才能删。
