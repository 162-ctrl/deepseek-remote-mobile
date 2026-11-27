package com.deepseek.remote.deepseek_remote_app

import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder

/**
 * 连接期间的前台服务：让 WSS 在 App 退到后台/锁屏时不被系统回收。
 *
 * 常驻通知内容：「已连接 <deviceName> · DeepSeek Remote」。
 * 断开连接时由 Dart 侧调用 stopForegroundService 停止。
 */
class ConnectionService : Service() {

    companion object {
        const val EXTRA_DEVICE_NAME = "device_name"
        const val NOTIFICATION_ID = NotificationHelper.CONNECTION_NOTIFICATION_ID
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        NotificationHelper.ensureChannels(this)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val deviceName = intent?.getStringExtra(EXTRA_DEVICE_NAME)
            ?.takeIf { it.isNotBlank() } ?: "真实电脑"
        val notification = NotificationHelper.connectionNotification(this, deviceName)
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(
                    NOTIFICATION_ID,
                    notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
                )
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
            START_STICKY
        } catch (e: Exception) {
            // 前台服务启动失败不影响连接的主流程。
            stopSelf()
            START_NOT_STICKY
        }
    }

    override fun onDestroy() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
        super.onDestroy()
    }
}
