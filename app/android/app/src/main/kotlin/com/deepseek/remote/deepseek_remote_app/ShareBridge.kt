package com.deepseek.remote.deepseek_remote_app

import android.app.Activity
import android.content.Intent
import android.net.Uri
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * M2.2 A4：分享卡系统分享桥。
 *
 * Dart 侧把渲染好的 PNG 字节传进来，这里写到 cacheDir/share/<fileName>，
 * 通过 [ShareFileProvider] 暴露为 content:// URI，再拉起系统分享面板
 * （ACTION_SEND, image/png）。
 */
class ShareBridge(
    private val activity: Activity,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler {

    companion object {
        const val CHANNEL = "deepseek_remote/share"
        private const val SHARE_DIR = "share"
    }

    private val channel = MethodChannel(messenger, CHANNEL)

    fun register() {
        channel.setMethodCallHandler(this)
    }

    fun dispose() {
        channel.setMethodCallHandler(null)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "shareImage" -> shareImage(call, result)
            else -> result.notImplemented()
        }
    }

    private fun shareImage(call: MethodCall, result: MethodChannel.Result) {
        val bytes = call.argument<ByteArray>("bytes")
        if (bytes == null || bytes.isEmpty()) {
            result.error("BAD_ARGS", "缺少图片字节", null)
            return
        }
        val rawName = call.argument<String>("fileName") ?: "deepseek-remote-share.png"
        val fileName = sanitizeName(rawName)
        val chooserTitle = call.argument<String>("chooserTitle") ?: "分享对话"
        try {
            val dir = File(activity.cacheDir, SHARE_DIR)
            if (!dir.exists() && !dir.mkdirs()) {
                result.success(false)
                return
            }
            // 清理旧分享卡，避免 cache 膨胀。
            dir.listFiles()?.forEach { old ->
                if (old.isFile && old.name != fileName) old.delete()
            }
            val file = File(dir, fileName)
            file.writeBytes(bytes)

            val uri: Uri = ShareFileProvider.uriFor(activity, fileName)
            val sendIntent = Intent(Intent.ACTION_SEND).apply {
                type = "image/png"
                putExtra(Intent.EXTRA_STREAM, uri)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            val chooser = Intent.createChooser(sendIntent, chooserTitle).apply {
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            // 把读权限显式授予所有能处理分享的 App（chooser 在某些 ROM 上不传递 grant）。
            activity.packageManager.queryIntentActivities(
                sendIntent,
                android.content.pm.PackageManager.MATCH_DEFAULT_ONLY,
            ).forEach { info ->
                activity.grantUriPermission(
                    info.activityInfo.packageName,
                    uri,
                    Intent.FLAG_GRANT_READ_URI_PERMISSION,
                )
            }
            activity.startActivity(chooser)
            result.success(true)
        } catch (e: Exception) {
            result.success(false)
        }
    }

    private fun sanitizeName(raw: String): String {
        val cleaned = raw.replace(Regex("[^A-Za-z0-9._-]"), "_").take(64)
        return if (cleaned.lowercase().endsWith(".png")) cleaned else "$cleaned.png"
    }
}
