package com.leandroamaro.medisync_v3

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.app.Activity
import android.os.Bundle
import android.os.SystemClock
import android.view.WindowManager

class MainActivity : FlutterActivity() {
    // Applies before the first frame, including login, vault, clinical overlays
    // and resumed activities. No temporary capture window for app previews.
    override fun onCreate(savedInstanceState: Bundle?) {
        window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        super.onCreate(savedInstanceState)
    }
    private var pendingPermission: MethodChannel.Result? = null
    private val channelId = "medisync-foreground"
    private var exportResult: MethodChannel.Result? = null
    private var exportHtml: String? = null
    private var exportStartedAt = 0L

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "medisync/readable-export")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "clear" -> {
                        exportHtml = null
                        exportResult?.error("locked", "Export cleared", null)
                        exportResult = null
                        result.success(null)
                    }
                    "save" -> {
                        val html = call.argument<String>("html")
                        if (html == null || html.length > 5_000_000 || exportResult != null) {
                            result.error("unavailable", "Export unavailable", null)
                        } else {
                            exportHtml = html
                            exportResult = result
                            exportStartedAt = SystemClock.elapsedRealtime()
                            try {
                                startActivityForResult(Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                                    addCategory(Intent.CATEGORY_OPENABLE)
                                    type = "text/html"
                                    putExtra(Intent.EXTRA_TITLE, "medisync-medical-records-${System.currentTimeMillis()}.html")
                                }, 6402)
                            } catch (_: Exception) {
                                exportHtml = null; exportResult = null
                                result.error("unavailable", "Choose a private destination and retry", null)
                            }
                        }
                    }
                    else -> result.notImplemented()
                }
            }
        val manager = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= 26) manager.createNotificationChannel(NotificationChannel(channelId, "Foreground appointment reminders", NotificationManager.IMPORTANCE_DEFAULT))
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "medisync/foreground-alerts")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "request" -> {
                        if (Build.VERSION.SDK_INT >= 33 && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
                            if (pendingPermission != null) result.success(false)
                            else {
                                pendingPermission = result
                                requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 6401)
                            }
                        } else result.success(manager.areNotificationsEnabled())
                    }
                    "clear" -> { manager.cancelAll(); result.success(null) }
                    "clearReminders" -> {
                        manager.activeNotifications.filter { it.tag == "reminder" }.forEach { manager.cancel(it.tag, it.id) }
                        result.success(null)
                    }
                    "show" -> {
                        if (!manager.areNotificationsEnabled() || !hasWindowFocus()) result.error("permission-denied", "Foreground notifications are unavailable", null)
                        else {
                            val id = call.argument<String>("id") ?: "appointment"
                            val workflow = call.argument<String>("kind") == "workflow"
                            val pending = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java), PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
                            // Fixed generic text. No names/reasons are accepted from Dart.
                            val builder = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(this, channelId) else Notification.Builder(this)
                            val notification = builder
                                .setSmallIcon(android.R.drawable.ic_dialog_info)
                                .setContentTitle(if (workflow) "MediSync update" else "MediSync reminder")
                                .setContentText(if (workflow) "A workflow status changed. Open MediSync to check current updates." else "An appointment is approaching. Open MediSync to check its current status.")
                                .setContentIntent(pending).setAutoCancel(true)
                                .setVisibility(Notification.VISIBILITY_PRIVATE).build()
                            manager.notify(if (workflow) "workflow" else "reminder", id.hashCode(), notification)
                            result.success(null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != 6402) return
        val result = exportResult
        val html = exportHtml
        val expired = SystemClock.elapsedRealtime() - exportStartedAt >= 15 * 60 * 1000L
        exportResult = null; exportHtml = null
        if (result == null) return
        try {
            if (resultCode != Activity.RESULT_OK || data?.data == null || html == null || expired) {
                result.error("cancelled", "Export cancelled", null)
            } else {
                val stream = contentResolver.openOutputStream(data.data!!, "wt")
                    ?: throw IllegalStateException("Destination unavailable")
                stream.use { it.write(html.toByteArray(Charsets.UTF_8)) }
                result.success(null)
            }
        } catch (_: Exception) {
            result.error("unavailable", "Export was not confirmed; retry", null)
        }
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == 6401) {
            pendingPermission?.success(grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED)
            pendingPermission = null
        }
    }
}
