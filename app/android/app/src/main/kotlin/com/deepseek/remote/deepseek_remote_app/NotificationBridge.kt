package com.deepseek.remote.deepseek_remote_app

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * `deepseek_remote/notifications` 通道的原生实现。
 *
 * Dart 侧见 lib/services/notification_gateway.dart。所有方法都用
 * MethodChannel.Result 回复，权限请求走异步回调。
 */
class NotificationBridge(
    private val activity: Activity,
    messenger: BinaryMessenger
) : MethodChannel.MethodCallHandler {

    companion object {
        const val CHANNEL = "deepseek_remote/notifications"
        const val ACTION_APPROVAL = "com.deepseek.remote.deepseek_remote_app.APPROVAL"
        const val EXTRA_APPROVAL_ID = "approval_id"

        /** M4.4：通知栏「允许 / 拒绝」直接决定的 Intent action。 */
        const val ACTION_APPROVE = "com.deepseek.remote.deepseek_remote_app.APPROVE"
        const val ACTION_REJECT = "com.deepseek.remote.deepseek_remote_app.REJECT"

        /** M4.4：点击通知后 App 要跳去的页面。 */
        const val EXTRA_NOTIFICATION_ROUTE = "notification_route"
        const val ROUTE_TASKS = "tasks"
        const val ROUTE_APPROVAL = "approval"

        private const val NOTIFICATION_PERMISSION_REQUEST = 7301
    }

    private val channel = MethodChannel(messenger, CHANNEL)
    private var pendingPermissionResult: MethodChannel.Result? = null

    fun register() {
        channel.setMethodCallHandler(this)
        NotificationHelper.ensureChannels(activity)
    }

    fun dispose() {
        channel.setMethodCallHandler(null)
        pendingPermissionResult = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "showApproval" -> handleShowApproval(call, result)
            "cancelApproval" -> {
                val approvalId = call.argument<String>("approvalId")
                if (approvalId.isNullOrEmpty()) {
                    result.error("BAD_ARGS", "approvalId 不能为空", null)
                } else {
                    NotificationHelper.cancelApproval(activity, approvalId)
                    result.success(true)
                }
            }
            "showDisconnected" -> {
                NotificationHelper.showDisconnected(activity, call.argument<String>("reason"))
                result.success(true)
            }
            "clearDisconnected" -> {
                NotificationHelper.clearDisconnected(activity)
                result.success(true)
            }
            "startForegroundService" -> {
                val deviceName = call.argument<String>("deviceName") ?: ""
                result.success(startConnectionService(deviceName))
            }
            "stopForegroundService" -> {
                activity.stopService(Intent(activity, ConnectionService::class.java))
                result.success(true)
            }
            "requestPermission" -> requestNotificationPermission(result)
            "showTaskUpdate" -> {
                val key = call.argument<String>("key")
                if (key.isNullOrEmpty()) {
                    result.error("BAD_ARGS", "key 不能为空", null)
                } else {
                    NotificationHelper.showTaskUpdate(
                        activity,
                        key,
                        call.argument<String>("title") ?: "任务状态更新",
                        call.argument<String>("body") ?: "",
                        call.argument<String>("status") ?: "completed"
                    )
                    result.success(true)
                }
            }
            "showApprovalAction" -> {
                val id = call.argument<String>("id")
                val approvalId = call.argument<String>("approvalId")
                if (id.isNullOrEmpty() || approvalId.isNullOrEmpty()) {
                    result.error("BAD_ARGS", "id / approvalId 不能为空", null)
                } else {
                    NotificationHelper.showApprovalAction(
                        activity,
                        id,
                        approvalId,
                        call.argument<String>("title") ?: "有一项操作需要授权",
                        call.argument<String>("body") ?: ""
                    )
                    result.success(true)
                }
            }
            "cancelTaskUpdate" -> {
                val id = call.argument<String>("id")
                if (!id.isNullOrEmpty()) NotificationHelper.cancelTaskUpdate(activity, id)
                result.success(true)
            }
            "getInitialApprovalId" -> {
                val intent = activity.intent
                // M4.4：通知栏「允许 / 拒绝」冷启动时只回传决定，不当作点击审批。
                val decision = when (intent?.action) {
                    ACTION_APPROVE -> true
                    ACTION_REJECT -> false
                    else -> null
                }
                val approvalId = intent?.getStringExtra(EXTRA_APPROVAL_ID)
                intent?.removeExtra(EXTRA_APPROVAL_ID)
                intent?.removeExtra(EXTRA_NOTIFICATION_ROUTE)
                if (decision != null && !approvalId.isNullOrEmpty()) {
                    NotificationHelper.cancelApproval(activity, approvalId)
                    channel.invokeMethod(
                        "onApprovalDecision",
                        mapOf("approvalId" to approvalId, "approved" to decision)
                    )
                    result.success(null)
                } else {
                    result.success(approvalId)
                }
            }
            else -> result.notImplemented()
        }
    }

    private fun handleShowApproval(call: MethodCall, result: MethodChannel.Result) {
        val approvalId = call.argument<String>("approvalId")
        if (approvalId.isNullOrEmpty()) {
            result.error("BAD_ARGS", "approvalId 不能为空", null)
            return
        }
        val title = call.argument<String>("title") ?: "有一项操作需要授权"
        val body = call.argument<String>("body") ?: ""
        NotificationHelper.showApproval(activity, approvalId, title, body)
        result.success(true)
    }

    private fun startConnectionService(deviceName: String): Boolean {
        val intent = Intent(activity, ConnectionService::class.java)
            .putExtra(ConnectionService.EXTRA_DEVICE_NAME, deviceName)
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                activity.startForegroundService(intent)
            } else {
                activity.startService(intent)
            }
            true
        } catch (e: Exception) {
            // Android 12+ 后台启动前台服务可能受限：失败不影响连接主流程。
            false
        }
    }

    private fun requestNotificationPermission(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            // Android 12 及以下默认有通知权限。
            result.success(true)
            return
        }
        if (activity.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED
        ) {
            result.success(true)
            return
        }
        // 重复请求时先失败掉上一个等待中的结果，避免泄漏。
        pendingPermissionResult?.success(false)
        pendingPermissionResult = result
        activity.requestPermissions(
            arrayOf(Manifest.permission.POST_NOTIFICATIONS),
            NOTIFICATION_PERMISSION_REQUEST
        )
    }

    fun onRequestPermissionsResult(requestCode: Int, grantResults: IntArray) {
        if (requestCode != NOTIFICATION_PERMISSION_REQUEST) return
        val granted = grantResults.isNotEmpty() &&
            grantResults[0] == PackageManager.PERMISSION_GRANTED
        pendingPermissionResult?.success(granted)
        pendingPermissionResult = null
    }

    /** 通知点击（热启动）把 approvalId 回传给 Flutter。 */
    fun handleIntent(intent: Intent?) {
        if (intent == null) return
        // M4.4：通知栏直接「允许 / 拒绝」——先把决定回传给 Dart，
        // 这条 intent 不再当作「点了审批通知」处理。
        val decision = when (intent.action) {
            ACTION_APPROVE -> true
            ACTION_REJECT -> false
            else -> null
        }
        val id = intent.getStringExtra(EXTRA_APPROVAL_ID)
        intent.removeExtra(EXTRA_APPROVAL_ID)
        intent.removeExtra(EXTRA_NOTIFICATION_ROUTE)
        if (decision != null && !id.isNullOrEmpty()) {
            NotificationHelper.cancelApproval(activity, id)
            channel.invokeMethod(
                "onApprovalDecision",
                mapOf("approvalId" to id, "approved" to decision)
            )
            return
        }
        if (id.isNullOrEmpty()) return
        channel.invokeMethod("onApprovalTapped", id)
    }
}
