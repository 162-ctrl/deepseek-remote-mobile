package com.deepseek.remote.deepseek_remote_app

import android.app.Activity
import android.content.Intent
import android.os.Build
import android.provider.Settings
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * M2.5 A2：应用内更新桥（MethodChannel `deepseek_remote/update`）。
 *
 * 能力边界（与契约一致）：
 * - 只负责「缓存目录 / 未知来源安装权限 / 打开授权页 / 调起系统安装器」；
 * - 不做静默安装：普通应用没有 INSTALL_PACKAGES 系统权限，系统安装界面
 *   必须由用户点一次「安装/更新」，这是 Android 的安全设计，不是实现缺陷；
 * - APK 文件通过 [ShareFileProvider] 暴露成 content:// URI，避免
 *   file:// 在 Android 7+ 触发 FileUriExposedException。
 */
class UpdateBridge(
    private val activity: Activity,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler {

    companion object {
        const val CHANNEL = "deepseek_remote/update"
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
            "getCacheDirectory" -> result.success(activity.cacheDir.absolutePath)
            "canInstallPackages" -> result.success(canInstallPackages())
            "openInstallSettings" -> result.success(openInstallSettings())
            "openUrl" -> result.success(openUrl(call))
            "installApk" -> installApk(call, result)
            else -> result.notImplemented()
        }
    }

    /** M4.33：用系统浏览器打开一个网页（目前只用于「去充值」的官方充值页）。 */
    private fun openUrl(call: MethodCall): Boolean {
        val url = call.argument<String>("url")
        if (url.isNullOrBlank()) return false
        if (!url.startsWith("https://") && !url.startsWith("http://")) return false
        return try {
            val intent = Intent(Intent.ACTION_VIEW).apply {
                data = android.net.Uri.parse(url)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            activity.startActivity(intent)
            true
        } catch (_: Exception) {
            false
        }
    }

    /** Android 8+ 需要用户对「安装未知应用」单独授权；低版本恒为 true。 */
    private fun canInstallPackages(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return true
        return try {
            activity.packageManager.canRequestPackageInstalls()
        } catch (_: Exception) {
            false
        }
    }

    private fun openInstallSettings(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return true
        return try {
            val intent = Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES).apply {
                data = android.net.Uri.parse("package:${activity.packageName}")
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            activity.startActivity(intent)
            true
        } catch (_: Exception) {
            false
        }
    }

    private fun installApk(call: MethodCall, result: MethodChannel.Result) {
        val path = call.argument<String>("path")
        if (path.isNullOrBlank()) {
            result.error("BAD_ARGS", "缺少 APK 路径", null)
            return
        }
        val file = File(path)
        if (!file.exists() || file.length() == 0L) {
            result.success(false)
            return
        }
        try {
            val uri = ShareFileProvider.uriForUpdate(activity, file.name)
            val intent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, "application/vnd.android.package-archive")
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            activity.startActivity(intent)
            result.success(true)
        } catch (_: Exception) {
            result.success(false)
        }
    }
}
