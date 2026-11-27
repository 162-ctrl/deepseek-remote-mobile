package com.deepseek.remote.deepseek_remote_app

import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {

    private var notificationBridge: NotificationBridge? = null
    private var settingsBridge: SettingsBridge? = null
    private var shareBridge: ShareBridge? = null
    private var updateBridge: UpdateBridge? = null
    private var fileOpenBridge: FileOpenBridge? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        notificationBridge = NotificationBridge(this, messenger).also {
            it.register()
        }
        // M2.2 A3：主题外观持久化（SharedPreferences）。
        settingsBridge = SettingsBridge(this, messenger).also {
            it.register()
        }
        // M2.2 A4：分享卡系统分享（cacheDir/share + content:// Provider）。
        shareBridge = ShareBridge(this, messenger).also {
            it.register()
        }
        // M2.5 A2：应用内在线更新（缓存目录 + 调起系统安装器）。
        updateBridge = UpdateBridge(this, messenger).also {
            it.register()
        }
        // M4.9：工作区文件预览（cacheDir/preview + content:// + ACTION_VIEW）。
        fileOpenBridge = FileOpenBridge(this, messenger)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        notificationBridge?.handleIntent(intent)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        notificationBridge?.onRequestPermissionsResult(requestCode, grantResults)
    }

    override fun onDestroy() {
        notificationBridge?.dispose()
        notificationBridge = null
        settingsBridge?.dispose()
        settingsBridge = null
        shareBridge?.dispose()
        shareBridge = null
        updateBridge?.dispose()
        updateBridge = null
        fileOpenBridge = null
        super.onDestroy()
    }
}
