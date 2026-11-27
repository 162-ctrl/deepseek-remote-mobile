# 签名与发布说明

当前 `dist/` 里的 APK 由 `flutter build apk --release` 产出，使用 Flutter 默认的 debug 签名配置（`android/app/build.gradle.kts` 未配置 release signingConfig），可以直接安装，但不能作为正式商店包。

## 生成正式签名

```powershell
keytool -genkeypair -v -keystore "$env:USERPROFILE\.dsh\deepseek-remote.jks" `
  -alias deepseek-remote -keyalg RSA -keysize 2048 -validity 10000 `
  -storepass <storepass> -keypass <keypass> -dname "CN=DeepSeek Remote, O=Personal, C=CN"
```

在 `android/key.properties` 写入（不要提交到仓库）：

```properties
storePassword=<storepass>
keyPassword=<keypass>
keyAlias=deepseek-remote
storeFile=C:/Users/user/.dsh/deepseek-remote.jks
```

`android/app/build.gradle.kts` 的 `android { signingConfigs { create("release") { ... } } buildTypes { release { signingConfig = signingConfigs.getByName("release") } } }` 读取该文件。

## 构建与校验

```powershell
flutter build apk --release
# 产物 build/app/outputs/flutter-apk/app-release.apk
& "$env:ANDROID_HOME\build-tools\35.0.0\apksigner.bat" verify --print-certs <apk>
Get-FileHash <apk> -Algorithm SHA256
```

## 发布前检查

1. `flutter test` 全绿（M4.12 实测 344 个用例）；
2. `apksigner verify` 通过，证书指纹记录在发布说明里；
3. 记录 `versionCode` / `versionName` / SHA256 / 文件大小；
4. 回滚方式：保留上一版 `dist/DeepSeek-Remote-AI-<version>.apk`，`adb install -r` 旧包即可回退（同签名才行）。
