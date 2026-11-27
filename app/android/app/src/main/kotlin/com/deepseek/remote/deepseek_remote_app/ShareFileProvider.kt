package com.deepseek.remote.deepseek_remote_app

import android.content.ContentProvider
import android.content.ContentValues
import android.content.Context
import android.database.Cursor
import android.database.MatrixCursor
import android.net.Uri
import android.os.ParcelFileDescriptor
import android.provider.OpenableColumns
import java.io.File
import java.io.FileNotFoundException

/**
 * M2.2 A4：最小化的 FileProvider 实现。
 *
 * 契约要求用 FileProvider 通过 content:// 分享 PNG；为了保持「零新增依赖」
 * （不引入 androidx.core），这里用系统 [ContentProvider] 自己实现，只暴露
 * `cacheDir/share/` 目录，authority 仍为 `${applicationId}.fileprovider`。
 */
class ShareFileProvider : ContentProvider() {

    companion object {
        const val AUTHORITY_SUFFIX = ".fileprovider"
        private const val SHARE_DIR = "share"
        private const val SHARE_FILES_DIR = "files"

        /** M2.5：APK 下载缓存目录（与 UpdateService 的 `{cacheDir}/updates` 对齐）。 */
        private const val UPDATE_DIR = "updates"

        /** M4.9：预览缓存目录（与 FileOpenBridge 的 `cacheDir/preview` 对齐）。 */
        private const val PREVIEW_DIR = "preview"

        fun authority(context: Context): String =
            context.packageName + AUTHORITY_SUFFIX

        /** 为 cacheDir/share/<fileName> 生成 content:// URI。 */
        fun uriFor(context: Context, fileName: String): Uri =
            builder(context, listOf(SHARE_DIR), fileName)

        /** M2.5：为 cacheDir/updates/<fileName> 生成 content:// URI（安装器用）。 */
        fun uriForUpdate(context: Context, fileName: String): Uri =
            builder(context, listOf(UPDATE_DIR), fileName)

        /**
         * M4.72：「用其他应用打开」用的 URI（cacheDir/preview/<fileName>）。
         *
         * 之前这里调的是 androidx 的 `FileProvider.getUriForFile`，但应用里注册的
         * provider 是本类（没有 `FILE_PROVIDER_PATHS` 元数据），于是 androidx 解析
         * 路径时直接抛异常——打开和分享双双失败。改成自己拼 URI。
         */
        fun uriForPreview(context: Context, fileName: String): Uri =
            builder(context, listOf(PREVIEW_DIR), fileName)

        /** M4.72：分享面板用的 URI（cacheDir/share/files/<fileName>）。 */
        fun uriForShare(context: Context, fileName: String): Uri =
            builder(context, listOf(SHARE_DIR, SHARE_FILES_DIR), fileName)

        private fun builder(context: Context, dirs: List<String>, fileName: String):
            Uri {
            val builder = Uri.Builder()
                .scheme("content")
                .authority(authority(context))
            for (dir in dirs) {
                builder.appendPath(dir)
            }
            return builder.appendPath(fileName).build()
        }

        private fun resolveFile(context: Context, uri: Uri): File {
            val segments = uri.pathSegments
            val name = segments.lastOrNull()
            if (name.isNullOrEmpty() || name.contains("..")) {
                throw FileNotFoundException("非法的分享文件名: $uri")
            }
            val parent = when (segments.size) {
                2 -> if (segments[0] == SHARE_DIR || segments[0] == UPDATE_DIR ||
                    segments[0] == PREVIEW_DIR) {
                    segments[0]
                } else {
                    throw FileNotFoundException("非法的分享目录: $uri")
                }
                3 -> if (segments[0] == SHARE_DIR && segments[1] == SHARE_FILES_DIR) {
                    "$SHARE_DIR/$SHARE_FILES_DIR"
                } else {
                    throw FileNotFoundException("非法的分享目录: $uri")
                }
                else -> throw FileNotFoundException("非法的分享路径: $uri")
            }
            return File(File(context.cacheDir, parent), name)
        }
    }

    override fun onCreate(): Boolean = true

    override fun query(
        uri: Uri,
        projection: Array<out String>?,
        selection: String?,
        selectionArgs: Array<out String>?,
        sortOrder: String?,
    ): Cursor? {
        val ctx = context ?: return null
        val file = try {
            resolveFile(ctx, uri)
        } catch (_: FileNotFoundException) {
            return null
        }
        if (!file.exists()) return null
        val columns =
            projection ?: arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE)
        val cursor = MatrixCursor(columns, 1)
        val row = cursor.newRow()
        for (column in columns) {
            when (column) {
                OpenableColumns.DISPLAY_NAME -> row.add(file.name)
                OpenableColumns.SIZE -> row.add(file.length())
                else -> row.add(null)
            }
        }
        return cursor
    }

    override fun getType(uri: Uri): String? {
        val name = uri.lastPathSegment?.lowercase() ?: return "application/octet-stream"
        return when {
            name.endsWith(".png") -> "image/png"
            name.endsWith(".jpg") || name.endsWith(".jpeg") -> "image/jpeg"
            name.endsWith(".webp") -> "image/webp"
            name.endsWith(".gif") -> "image/gif"
            name.endsWith(".pdf") -> "application/pdf"
            name.endsWith(".docx") ->
                "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
            name.endsWith(".doc") -> "application/msword"
            name.endsWith(".xlsx") ->
                "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
            name.endsWith(".xls") -> "application/vnd.ms-excel"
            name.endsWith(".pptx") ->
                "application/vnd.openxmlformats-officedocument.presentationml.presentation"
            name.endsWith(".txt") || name.endsWith(".md") -> "text/plain"
            // M2.5：安装器需要识别 APK 的 MIME，否则部分 ROM 会拒绝打开。
            name.endsWith(".apk") -> "application/vnd.android.package-archive"
            else -> "application/octet-stream"
        }
    }

    override fun openFile(uri: Uri, mode: String): ParcelFileDescriptor {
        val ctx = context ?: throw FileNotFoundException("provider 未初始化")
        val file = resolveFile(ctx, uri)
        if (!file.exists()) throw FileNotFoundException("分享文件不存在: $uri")
        return ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY)
    }

    override fun insert(uri: Uri, values: ContentValues?): Uri? =
        throw UnsupportedOperationException("分享 Provider 为只读")

    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?): Int = 0

    override fun update(
        uri: Uri,
        values: ContentValues?,
        selection: String?,
        selectionArgs: Array<out String>?,
    ): Int = 0
}
