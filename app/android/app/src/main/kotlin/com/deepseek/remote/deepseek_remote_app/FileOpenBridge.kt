package com.deepseek.remote.deepseek_remote_app

import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.webkit.MimeTypeMap
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * M4.9：把手机端下载到的文件交给系统应用打开。
 *
 * 字节先写进 `cacheDir/preview/`，再用 [ShareFileProvider]（file_paths.xml 的
 * `preview/` 路径）换成 `content://` URI，最后 `ACTION_VIEW` 拉起能处理的 App
 * （WPS 打开 PDF/Word、系统看图打开图片）。全程不暴露 `file://`，避免
 * FileUriExposedException。
 */
class FileOpenBridge(private val context: Context, messenger: BinaryMessenger) :
    MethodChannel.MethodCallHandler {

    companion object {
        const val CHANNEL = "deepseek_remote/files"
        private const val PREVIEW_DIR = "preview"
        private const val SHARE_DIR = "share/files"
        private const val MAX_BYTES = 40 * 1024 * 1024
    }

    init {
        MethodChannel(messenger, CHANNEL).setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "openBytes" -> handleOpenBytes(call, result)
            "shareBytes" -> handleShareBytes(call, result)
            "canOpenBytes" -> handleCanOpenBytes(call, result)
            else -> result.notImplemented()
        }
    }

    /**
     * M4.70：先问一句有没有应用能打开。
     *
     * 手机上没装 WPS 时 .docx 怎么点都打不开，与其让人点了再看 toast，
     * 不如把按钮藏掉。这里只查 intent 能不能被解析，不真的启动应用。
     */
    private fun handleCanOpenBytes(call: MethodCall, result: MethodChannel.Result) {
        val rawName = call.argument<String>("fileName") ?: "文件"
        val mimeType = call.argument<String>("mimeType")?.takeIf { it.isNotBlank() }
            ?: guessMimeType(sanitize(rawName))
        val resolvable = try {
            val intent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(Uri.parse("content://placeholder"), mimeType)
            }
            // M4.71：用 queryIntentActivities 而不是 resolveActivity —— 前者一次拿到
            // 所有候选（在 manifest 的 <queries> 范围内），不会被「默认打开方式未设」
            // 之类的情况判成没有。
            val matches = context.packageManager.queryIntentActivities(intent, 0)
            matches.isNotEmpty() || intent.resolveActivity(context.packageManager) != null
        } catch (_: Exception) {
            true
        }
        result.success(resolvable)
    }

    /**
     * M4.64：交给系统分享面板。
     *
     * 手机上没装能「打开」某类文件的应用时（典型是没装 WPS 的 .docx），
     * 分享面板通常还在——可以先发到微信/QQ/文件管理器，或者发给别的设备。
     */
    private fun handleShareBytes(call: MethodCall, result: MethodChannel.Result) {
        val file = prepareFile(call, SHARE_DIR, result, "分享") ?: return
        val rawName = call.argument<String>("fileName") ?: "文件"
        val mimeType = call.argument<String>("mimeType")?.takeIf { it.isNotBlank() }
            ?: guessMimeType(sanitize(rawName))
        try {
            val uri: Uri = ShareFileProvider.uriForShare(context, file.name)
            val send = Intent(Intent.ACTION_SEND).apply {
                type = mimeType
                putExtra(Intent.EXTRA_STREAM, uri)
                putExtra(Intent.EXTRA_TITLE, sanitize(rawName))
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            val chooser = Intent.createChooser(send, "分享文件").apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            context.startActivity(chooser)
            result.success(true)
        } catch (error: Exception) {
            result.error("SHARE_FAILED", error.message ?: error.javaClass.simpleName, null)
        }
    }

    private fun handleOpenBytes(call: MethodCall, result: MethodChannel.Result) {
        val file = prepareFile(call, PREVIEW_DIR, result, "用其他应用打开") ?: return
        val rawName = call.argument<String>("fileName") ?: "文件"
        val mimeType = call.argument<String>("mimeType")?.takeIf { it.isNotBlank() }
            ?: guessMimeType(sanitize(rawName))
        try {
            val uri: Uri = ShareFileProvider.uriForPreview(context, file.name)
            val view = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, mimeType)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            // M4.73：一律走系统选择器 —— 用户问「能不能选一个应用」，ACTION_VIEW 在没有
            // 默认打开方式时才会弹列表，有默认就更不会弹。createChooser 每次都给候选列表。
            val chooser = Intent.createChooser(view, "用其他应用打开").apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            try {
                context.startActivity(chooser)
            } catch (_: ActivityNotFoundException) {
                result.error("NO_APP", "手机上没有能打开这种文件的应用", null)
                return
            }
            result.success(true)
        } catch (error: Exception) {
            result.error("OPEN_FAILED", error.message ?: error.javaClass.simpleName, null)
        }
    }

    /** 校验字节、写进缓存目录，返回落盘文件；失败时已通过 result 回报并返回 null。 */
    private fun prepareFile(
        call: MethodCall,
        dirName: String,
        result: MethodChannel.Result,
        action: String,
    ): File? {
        val bytes = call.argument<ByteArray>("bytes")
        if (bytes == null || bytes.isEmpty()) {
            result.error("EMPTY", "文件内容为空", null)
            return null
        }
        if (bytes.size > MAX_BYTES) {
            result.error("TOO_LARGE", "文件太大，无法$action", null)
            return null
        }
        val fileName = sanitize(call.argument<String>("fileName") ?: "文件")
        return try {
            val dir = File(context.cacheDir, dirName)
            if (!dir.exists() && !dir.mkdirs()) {
                result.error("IO", "无法创建缓存目录", null)
                return null
            }
            val file = File(dir, fileName)
            file.writeBytes(bytes)
            file
        } catch (error: Exception) {
            result.error("IO", "写入缓存失败：${error.message}", null)
            null
        }
    }

    private fun sanitize(name: String): String {
        val base = name.substringAfterLast('/').substringAfterLast('\\').ifBlank { "文件" }
        val cleaned = base.replace(Regex("[\\\\/:*?\"<>|]"), "_").trim()
        return if (cleaned.length <= 100) cleaned else cleaned.take(100)
    }

    private fun guessMimeType(fileName: String): String {
        val ext = fileName.substringAfterLast('.', "").lowercase()
        val mapped = MimeTypeMap.getSingleton().getMimeTypeFromExtension(ext)
        return mapped ?: "application/octet-stream"
    }
}
