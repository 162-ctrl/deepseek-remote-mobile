package com.deepseek.remote.deepseek_remote_app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build

/**
 * 通知渠道、通知构建与取消。
 *
 * 全部使用平台 API（Notification.Builder / NotificationChannel / PendingIntent），
 * 不引入 androidx 依赖，避免新增 gradle 依赖。
 */
object NotificationHelper {
    const val CHANNEL_APPROVAL = "approval_alerts"
    const val CHANNEL_CONNECTION = "connection_status"

    /** M4.4：任务完成/失败通知渠道。 */
    const val CHANNEL_TASK = "task_updates"

    const val CONNECTION_NOTIFICATION_ID = 7302
    const val DISCONNECTED_NOTIFICATION_ID = 7303

    /** M4.4：任务通知 id 的基准值（按 sessionKey.hashCode 偏移，避开连接类固定 id）。 */
    const val TASK_NOTIFICATION_BASE = 7310

    const val TAG_DISCONNECTED = "connection_lost"

    private const val CHANNEL_APPROVAL_NAME = "需要授权"
    private const val CHANNEL_CONNECTION_NAME = "连接状态"
    private const val CHANNEL_TASK_NAME = "任务进度"

    /** 必须在任何 notify / startForeground 之前调用；可重复调用。 */
    fun ensureChannels(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (manager.getNotificationChannel(CHANNEL_APPROVAL) == null) {
            val channel = NotificationChannel(
                CHANNEL_APPROVAL,
                CHANNEL_APPROVAL_NAME,
                NotificationManager.IMPORTANCE_HIGH
            )
            channel.description = "高风险操作需要你在手机上确认"
            channel.enableVibration(true)
            channel.setShowBadge(true)
            manager.createNotificationChannel(channel)
        }
        if (manager.getNotificationChannel(CHANNEL_CONNECTION) == null) {
            val channel = NotificationChannel(
                CHANNEL_CONNECTION,
                CHANNEL_CONNECTION_NAME,
                NotificationManager.IMPORTANCE_LOW
            )
            channel.description = "保持与电脑的连接，避免后台被系统回收"
            channel.setShowBadge(false)
            channel.setSound(null, null)
            manager.createNotificationChannel(channel)
        }
        if (manager.getNotificationChannel(CHANNEL_TASK) == null) {
            val channel = NotificationChannel(
                CHANNEL_TASK,
                CHANNEL_TASK_NAME,
                NotificationManager.IMPORTANCE_HIGH
            )
            channel.description = "电脑上的任务做完或需要你授权时提醒你"
            channel.enableVibration(true)
            channel.setShowBadge(true)
            manager.createNotificationChannel(channel)
        }
    }

    /** M4.4：任务完成/失败/取消通知；点击回到 App。 */
    fun showTaskUpdate(
        context: Context,
        key: String,
        title: String,
        body: String,
        status: String
    ) {
        ensureChannels(context)
        val rawIntent = Intent(context, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
            putExtra(NotificationBridge.EXTRA_NOTIFICATION_ROUTE, NotificationBridge.ROUTE_TASKS)
        }
        val requestCode = TASK_NOTIFICATION_BASE + key.hashCode().and(0xFFFF)
        val pendingIntent = PendingIntent.getActivity(
            context,
            requestCode,
            rawIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val builder = builder(context, CHANNEL_TASK)
            .setSmallIcon(R.drawable.ic_stat_remote)
            .setContentTitle(title)
            .setContentText(body)
            .setStyle(Notification.BigTextStyle().bigText(body))
            .setCategory(
                if (status == "failed") Notification.CATEGORY_ERROR else Notification.CATEGORY_STATUS
            )
            .setAutoCancel(true)
            .setContentIntent(pendingIntent)
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            builder.setPriority(Notification.PRIORITY_HIGH)
            builder.setDefaults(Notification.DEFAULT_ALL)
        }
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        manager.notify(key, requestCode, builder.build())
    }

    fun cancelTaskUpdate(context: Context, id: String) {
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        manager.cancel(id, TASK_NOTIFICATION_BASE + id.hashCode().and(0xFFFF))
    }

    /** M4.4：等待授权的可操作通知——「允许 / 拒绝」直接在通知栏里点。 */
    fun showApprovalAction(
        context: Context,
        id: String,
        approvalId: String,
        title: String,
        body: String
    ) {
        ensureChannels(context)
        val requestCode = TASK_NOTIFICATION_BASE + id.hashCode().and(0xFFFF)
        val openIntent = Intent(context, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
            putExtra(NotificationBridge.EXTRA_NOTIFICATION_ROUTE, NotificationBridge.ROUTE_APPROVAL)
            putExtra(NotificationBridge.EXTRA_APPROVAL_ID, approvalId)
        }
        val contentIntent = PendingIntent.getActivity(
            context,
            requestCode,
            openIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val actionIntent = PendingIntent.getActivity(
            context,
            requestCode + 1,
            approvalDecisionIntent(context, approvalId, NotificationBridge.ACTION_APPROVE),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val rejectIntent = PendingIntent.getActivity(
            context,
            requestCode + 2,
            approvalDecisionIntent(context, approvalId, NotificationBridge.ACTION_REJECT),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val builder = builder(context, CHANNEL_APPROVAL)
            .setSmallIcon(R.drawable.ic_stat_remote)
            .setContentTitle(title)
            .setContentText(body)
            .setStyle(Notification.BigTextStyle().bigText(body))
            .setCategory(Notification.CATEGORY_MESSAGE)
            .setAutoCancel(false)
            .setOngoing(true)
            .setContentIntent(contentIntent)
            .addAction(0, "允许", actionIntent)
            .addAction(0, "拒绝", rejectIntent)
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            builder.setPriority(Notification.PRIORITY_HIGH)
            builder.setDefaults(Notification.DEFAULT_ALL)
        }
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        manager.notify(id, requestCode, builder.build())
    }

    private fun approvalDecisionIntent(
        context: Context,
        approvalId: String,
        action: String
    ): Intent = Intent(context, MainActivity::class.java).apply {
        this.action = action
        putExtra(NotificationBridge.EXTRA_APPROVAL_ID, approvalId)
        flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
    }

    fun showApproval(context: Context, approvalId: String, title: String, body: String) {
        ensureChannels(context)
        val notification = approvalNotification(context, approvalId, title, body)
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        // tag = approvalId：同一审批不会重复堆叠，也方便按 tag 取消。
        manager.notify(approvalId, approvalId.hashCode(), notification)
    }

    fun cancelApproval(context: Context, approvalId: String) {
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        manager.cancel(approvalId, approvalId.hashCode())
    }

    fun showDisconnected(context: Context, reason: String?) {
        ensureChannels(context)
        val body = if (reason.isNullOrBlank()) "已断开与电脑的连接" else "已断开与电脑的连接：$reason"
        val rawIntent = Intent(context, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val pendingIntent = PendingIntent.getActivity(
            context,
            DISCONNECTED_NOTIFICATION_ID,
            rawIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val builder = builder(context, CHANNEL_APPROVAL)
            .setSmallIcon(R.drawable.ic_stat_remote)
            .setContentTitle("已断开与电脑的连接")
            .setContentText(body)
            .setStyle(Notification.BigTextStyle().bigText(body))
            .setCategory(Notification.CATEGORY_ALARM)
            .setAutoCancel(true)
            .setContentIntent(pendingIntent)
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            builder.setPriority(Notification.PRIORITY_HIGH)
            builder.setDefaults(Notification.DEFAULT_ALL)
        }
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        manager.notify(TAG_DISCONNECTED, DISCONNECTED_NOTIFICATION_ID, builder.build())
    }

    fun clearDisconnected(context: Context) {
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        manager.cancel(TAG_DISCONNECTED, DISCONNECTED_NOTIFICATION_ID)
    }

    /** 前台服务常驻通知：`已连接 <deviceName> · DeepSeek Remote`。 */
    fun connectionNotification(context: Context, deviceName: String): Notification {
        ensureChannels(context)
        val rawIntent = Intent(context, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val pendingIntent = PendingIntent.getActivity(
            context,
            CONNECTION_NOTIFICATION_ID,
            rawIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val builder = builder(context, CHANNEL_CONNECTION)
            .setSmallIcon(R.drawable.ic_stat_remote)
            .setContentTitle("DeepSeek Remote")
            .setContentText("已连接 $deviceName · DeepSeek Remote")
            .setOngoing(true)
            .setShowWhen(false)
            .setContentIntent(pendingIntent)
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            builder.setPriority(Notification.PRIORITY_LOW)
        }
        return builder.build()
    }

    private fun approvalNotification(
        context: Context,
        approvalId: String,
        title: String,
        body: String
    ): Notification {
        val intent = Intent(context, MainActivity::class.java).apply {
            action = NotificationBridge.ACTION_APPROVAL
            putExtra(NotificationBridge.EXTRA_APPROVAL_ID, approvalId)
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val pendingIntent = PendingIntent.getActivity(
            context,
            approvalId.hashCode(),
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val builder = builder(context, CHANNEL_APPROVAL)
            .setSmallIcon(R.drawable.ic_stat_remote)
            .setContentTitle(title)
            .setContentText(body)
            .setStyle(Notification.BigTextStyle().bigText(body))
            .setCategory(Notification.CATEGORY_MESSAGE)
            .setAutoCancel(true)
            .setContentIntent(pendingIntent)
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            builder.setPriority(Notification.PRIORITY_HIGH)
            builder.setDefaults(Notification.DEFAULT_ALL)
        }
        return builder.build()
    }

    private fun builder(context: Context, channelId: String): Notification.Builder {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(context, channelId)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(context)
        }
    }
}
