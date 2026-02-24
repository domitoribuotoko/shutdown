package com.example.shutdowner2

import android.util.Log
import androidx.work.CoroutineWorker
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.net.Socket
import java.util.concurrent.TimeUnit

/**
 * Проверяет доступность ПК по TCP и обновляет виджет.
 * В режиме pending_wol ждёт первого успешного ответа; в pending_shutdown — 3 подряд неудач.
 */
class WidgetStatusWorker(
    context: android.content.Context,
    params: WorkerParameters
) : CoroutineWorker(context, params) {

    override suspend fun doWork(): Result = withContext(Dispatchers.IO) {
        val ctx = applicationContext
        val prefs = ctx.getSharedPreferences(WidgetActionReceiver.PREFS_NAME, android.content.Context.MODE_PRIVATE)
        val pcIp = prefs.getString(WidgetActionReceiver.KEY_PC_IP, "192.168.31.94") ?: "192.168.31.94"
        val tcpPort = prefs.getString(WidgetActionReceiver.KEY_TCP_CHECK_PORT, "445")?.toIntOrNull() ?: 445
        val timeoutMs = prefs.getString(WidgetActionReceiver.KEY_CONNECT_TIMEOUT_SEC, "3")?.toIntOrNull()?.times(1000) ?: 3000
        var status = prefs.getString(WidgetActionReceiver.KEY_PC_STATUS, "off") ?: "off"

        val isOnline = try {
            Socket().use { socket ->
                socket.soTimeout = timeoutMs
                socket.connect(java.net.InetSocketAddress(pcIp, tcpPort), timeoutMs)
            }
            true
        } catch (e: Exception) {
            Log.d("PC_WIDGET", "Status check: PC unreachable ($pcIp:$tcpPort): ${e.message}")
            false
        }

        when (status) {
            "pending_wol" -> {
                if (isOnline) {
                    status = "on"
                    prefs.edit().putString(WidgetActionReceiver.KEY_PC_STATUS, status).apply()
                    WidgetActionReceiver.updateWidgetViews(ctx, status)
                    Log.d("PC_WIDGET", "Status check: PC came online (WoL)")
                }
                // иначе остаёмся pending_wol, перезапуск через 5 сек ниже
            }
            "pending_shutdown" -> {
                var failCount = prefs.getString(WidgetActionReceiver.KEY_SHUTDOWN_FAIL_COUNT, "0")?.toIntOrNull() ?: 0
                if (isOnline) {
                    failCount = 0
                    prefs.edit().putString(WidgetActionReceiver.KEY_SHUTDOWN_FAIL_COUNT, "0").apply()
                    Log.d("PC_WIDGET", "Status check: PC still online (shutdown wait)")
                } else {
                    failCount++
                    prefs.edit().putString(WidgetActionReceiver.KEY_SHUTDOWN_FAIL_COUNT, failCount.toString()).apply()
                    if (failCount >= WidgetActionReceiver.PENDING_FAILS_NEEDED) {
                        status = "off"
                        prefs.edit().putString(WidgetActionReceiver.KEY_PC_STATUS, status).apply()
                        WidgetActionReceiver.updateWidgetViews(ctx, status)
                        Log.d("PC_WIDGET", "Status check: PC off after $failCount failures")
                    }
                }
            }
            else -> {
                status = if (isOnline) "on" else "off"
                prefs.edit().putString(WidgetActionReceiver.KEY_PC_STATUS, status).apply()
                WidgetActionReceiver.updateWidgetViews(ctx, status)
                Log.d("PC_WIDGET", "Status check done: $status")
            }
        }

        status = prefs.getString(WidgetActionReceiver.KEY_PC_STATUS, "off") ?: "off"
        if (status == "pending_wol" || status == "pending_shutdown") {
            val next = OneTimeWorkRequestBuilder<WidgetStatusWorker>()
                .setInitialDelay(5, TimeUnit.SECONDS)
                .build()
            WorkManager.getInstance(ctx).enqueue(next)
        }
        Result.success()
    }
}
