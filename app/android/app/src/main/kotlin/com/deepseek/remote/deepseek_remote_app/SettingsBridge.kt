package com.deepseek.remote.deepseek_remote_app

import android.app.Activity
import android.content.Context
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * M2.2 A3：极简设置存储桥。
 *
 * Dart 侧 `MethodChannelSettingsGateway` 通过 `deepseek_remote/settings`
 * 读写键值对；当前只用于主题外观（app_theme_id），重启后保留。
 */
class SettingsBridge(
    private val context: Context,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler {

    companion object {
        const val CHANNEL = "deepseek_remote/settings"
        private const val PREFS_NAME = "deepseek_remote"
    }

    private val channel = MethodChannel(messenger, CHANNEL)
    private val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

    fun register() {
        channel.setMethodCallHandler(this)
    }

    fun dispose() {
        channel.setMethodCallHandler(null)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "getString" -> {
                val key = call.argument<String>("key")
                if (key.isNullOrBlank()) {
                    result.error("BAD_ARGS", "缺少 key", null)
                    return
                }
                result.success(prefs.getString(key, null))
            }

            "setString" -> {
                val key = call.argument<String>("key")
                val value = call.argument<String>("value")
                if (key.isNullOrBlank()) {
                    result.error("BAD_ARGS", "缺少 key", null)
                    return
                }
                val ok = prefs.edit().putString(key, value).commit()
                result.success(ok)
            }

            else -> result.notImplemented()
        }
    }
}
