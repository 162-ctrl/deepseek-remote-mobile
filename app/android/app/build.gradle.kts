import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.deepseek.remote.deepseek_remote_app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.deepseek.remote.deepseek_remote_app"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        // 对外版本名：Android 设置/安装器里显示这个名字（与 APK 文件名里的版本一致）。
        versionName = "0.4.67-m4.67"
    }

    // M4.44：release 用独立 keystore（密钥在仓库外，路径与口令来自 key.properties）。
    // 没有 key.properties 时退回 debug 签名，保证 clone 下来还能 flutter run --release。
    signingConfigs {
        create("release") {
            val propsFile = rootProject.file("key.properties")
            if (propsFile.exists()) {
                val props = Properties()
                FileInputStream(propsFile).use { props.load(it) }
                storeFile = file(props.getProperty("storeFile"))
                storePassword = props.getProperty("storePassword")
                keyAlias = props.getProperty("keyAlias")
                keyPassword = props.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            val propsFile = rootProject.file("key.properties")
            // M4.45：key.properties 里写 useDebugSigning=true 时仍用 debug 签名。
            // 原因：手机里装的旧 APK 是 debug 签名的，换成 release 签名后 Android 会拒绝覆盖安装
            // （报「软件包与现有软件包存在冲突」），只有卸载重装才能换签名，而卸载会清掉本地对话。
            // 想切成正式签名时把这一行去掉，然后先卸载旧版再装新版。
            val debugSigning = propsFile.exists() &&
                Properties().also { props -> FileInputStream(propsFile).use { props.load(it) } }
                    .getProperty("useDebugSigning") == "true"
            signingConfig = if (propsFile.exists() && !debugSigning) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
