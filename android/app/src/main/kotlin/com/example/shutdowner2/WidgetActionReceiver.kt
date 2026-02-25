package com.example.shutdowner2

import android.appwidget.AppWidgetManager
import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.net.wifi.WifiManager
import android.util.Log
import android.view.View
import android.widget.RemoteViews
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress

/**
 * Обрабатывает нажатие на виджет. Выполняет WoL или UDP shutdown в нативном коде,
 * без запуска Flutter — поэтому работает при полностью закрытом приложении.
 */
class WidgetActionReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent?) {
        if (intent?.action != ACTION_WIDGET_TAP) return
        Log.d("PC_WIDGET", "WidgetActionReceiver: tap received, running action in background")
        Thread {
            runAction(context)
        }.start()
    }

    private fun runAction(context: Context) {
        val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val status = prefs.getString(KEY_PC_STATUS, "off") ?: "off"
        val pcIp = prefs.getString(KEY_PC_IP, "192.168.31.94") ?: "192.168.31.94"
        val broadcastIp = prefs.getString(KEY_BROADCAST_IP, "192.168.31.255") ?: "192.168.31.255"
        val pcMac = prefs.getString(KEY_PC_MAC, "70:85:C2:DA:3D:A3") ?: "70:85:C2:DA:3D:A3"
        val udpPort = prefs.getString(KEY_UDP_PORT, "9999")?.toIntOrNull() ?: 9999
        val shutdownCmd = prefs.getString(KEY_SHUTDOWN_CMD, "SHUTDOWN") ?: "SHUTDOWN"

        val newStatus: String
        when (status) {
            "on" -> {
                Log.d("PC_WIDGET", "Sending UDP shutdown to $pcIp:$udpPort")
                sendUdpShutdown(pcIp, udpPort, shutdownCmd)
                newStatus = "pending_shutdown"
                prefs.edit().putString(KEY_SHUTDOWN_FAIL_COUNT, "0").apply()
            }
            "off" -> {
                Log.d("PC_WIDGET", "Sending WoL to $broadcastIp, MAC $pcMac (up to 3 attempts)")
                val wolOk = trySendWolWithRetries(broadcastIp, pcMac, maxAttempts = 3)
                val sameSubnet = isOnSameSubnetAsPc(context, pcIp)
                newStatus = when {
                    !wolOk -> "off"
                    !sameSubnet -> "off"
                    else -> "pending_wol"
                }
                if (!wolOk) Log.w("PC_WIDGET", "WoL failed after 3 attempts, staying in off")
                if (wolOk && !sameSubnet) Log.w("PC_WIDGET", "Device not on same subnet as PC, staying in off")
            }
            "pending_wol" -> {
                Log.d("PC_WIDGET", "Cancel waiting (WoL) -> off")
                newStatus = "off"
            }
            "pending_shutdown" -> {
                Log.d("PC_WIDGET", "Cancel waiting (shutdown) -> on")
                newStatus = "on"
            }
            else -> newStatus = status
        }

        prefs.edit().putString(KEY_PC_STATUS, newStatus).apply()
        updateWidget(context, newStatus)
        Log.d("PC_WIDGET", "Action done, widget status -> $newStatus")
        // Цепочка проверок через AlarmManager (работает при закрытом приложении)
        when (newStatus) {
            "pending_wol" -> {
                WidgetStatusAlarmReceiver.scheduleNextCheck(context.applicationContext, 10L)
                Log.d("PC_WIDGET", "Scheduled first status check in 10 sec (WoL, AlarmManager)")
            }
            "pending_shutdown" -> {
                WidgetStatusAlarmReceiver.scheduleNextCheck(context.applicationContext, 1L)
                Log.d("PC_WIDGET", "Scheduled first status check in 1 sec (shutdown, AlarmManager)")
            }
            else -> { }
        }
        context.sendBroadcast(
            Intent(WidgetSyncBridge.ACTION_WIDGET_TAPPED_SYNC).setPackage(context.packageName)
        )
    }

    /** Отправляет один WoL-пакет. Возвращает true, если отправка прошла без исключения. */
    private fun sendWol(broadcastIp: String, mac: String): Boolean {
        return try {
            val macBytes = mac.split(":", "-").map { it.toInt(16).toByte() }.toByteArray()
            if (macBytes.size != 6) return false
            val packet = ByteArray(6 + 6 * 16)
            for (i in 0..5) packet[i] = 0xFF.toByte()
            for (i in 0 until 16) System.arraycopy(macBytes, 0, packet, 6 + i * 6, 6)

            DatagramSocket().use { socket ->
                socket.broadcast = true
                val addr = InetAddress.getByName(broadcastIp)
                val dp = DatagramPacket(packet, packet.size, addr, WOL_PORT)
                socket.send(dp)
            }
            true
        } catch (e: Exception) {
            Log.e("PC_WIDGET", "WoL error", e)
            false
        }
    }

    /** До 3 попыток отправки WoL. Возвращает true, если хотя бы одна успешна. */
    private fun trySendWolWithRetries(broadcastIp: String, mac: String, maxAttempts: Int = 3): Boolean {
        repeat(maxAttempts) { attempt ->
            if (sendWol(broadcastIp, mac)) {
                Log.d("PC_WIDGET", "WoL sent successfully (attempt ${attempt + 1})")
                return true
            }
            if (attempt < maxAttempts - 1) Thread.sleep(WOL_RETRY_DELAY_MS)
        }
        return false
    }

    /**
     * Проверяет, что устройство в той же подсети, что и ПК (WoL broadcast доходит только в своей подсети).
     * Если не удаётся определить (нет WiFi и т.п.) — возвращает true, чтобы не ломать сценарии.
     */
    private fun isOnSameSubnetAsPc(context: Context, pcIp: String): Boolean {
        val wifiManager = context.applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager ?: return true
        val ipInt = wifiManager.connectionInfo?.ipAddress ?: 0
        if (ipInt == 0) return true
        @Suppress("DEPRECATION")
        val deviceIp = "${ipInt and 0xFF}.${ipInt shr 8 and 0xFF}.${ipInt shr 16 and 0xFF}.${ipInt shr 24 and 0xFF}"
        val devicePrefix = deviceIp.split(".").take(3).joinToString(".")
        val pcPrefix = pcIp.split(".").take(3).joinToString(".")
        return devicePrefix == pcPrefix
    }

    private fun sendUdpShutdown(ip: String, port: Int, command: String) {
        try {
            val data = command.toByteArray(Charsets.UTF_8)
            DatagramSocket().use { socket ->
                socket.broadcast = true
                val addr = InetAddress.getByName(ip)
                val dp = DatagramPacket(data, data.size, addr, port)
                socket.send(dp)
            }
        } catch (e: Exception) {
            Log.e("PC_WIDGET", "UDP shutdown error", e)
        }
    }

    private fun updateWidget(context: Context, status: String) {
        updateWidgetViews(context, status)
    }

    companion object {
        private const val WOL_RETRY_DELAY_MS = 400L
        const val ACTION_WIDGET_TAP = "com.example.shutdowner2.WIDGET_TAP"
        const val PREFS_NAME = "HomeWidgetPreferences"
        const val KEY_PC_STATUS = "pc_status"
        const val KEY_PC_IP = "pc_ip"
        const val KEY_BROADCAST_IP = "broadcast_ip"
        const val KEY_PC_MAC = "pc_mac"
        const val KEY_UDP_PORT = "udp_port"
        const val KEY_SHUTDOWN_CMD = "shutdown_cmd"
        const val KEY_TCP_CHECK_PORT = "tcp_check_port"
        const val KEY_CONNECT_TIMEOUT_SEC = "connect_timeout_sec"
        const val KEY_SHUTDOWN_FAIL_COUNT = "shutdown_fail_count"
        const val WOL_PORT = 9
        const val PENDING_FAILS_NEEDED = 3

        /** Обновляет виджет по статусу (вызывается из Receiver и из Worker). */
        @JvmStatic
        fun updateWidgetViews(context: Context, status: String) {
            val appWidgetManager = AppWidgetManager.getInstance(context)
            val componentName = ComponentName(context, HomeWidgetProvider::class.java)
            val ids = appWidgetManager.getAppWidgetIds(componentName)
            val (bgResId, iconResId, pending) = when (status) {
                "on" -> Triple(R.drawable.widget_circle_on, R.drawable.ic_widget_power_on, false)
                "off" -> Triple(R.drawable.widget_circle_off, R.drawable.ic_widget_power_off, false)
                "pending_wol", "pending_shutdown" -> Triple(R.drawable.widget_circle_white, 0, true)
                else -> Triple(R.drawable.widget_circle_white, 0, true)
            }
            for (id in ids) {
                val views = RemoteViews(context.packageName, R.layout.home_widget_layout)
                views.setInt(R.id.widget_circle_bg, "setBackgroundResource", bgResId)
                views.setViewVisibility(R.id.widget_icon, if (pending) View.GONE else View.VISIBLE)
                views.setViewVisibility(R.id.widget_progress, if (pending) View.VISIBLE else View.GONE)
                if (!pending) views.setImageViewResource(R.id.widget_icon, iconResId)
                val intent = Intent(context, WidgetActionReceiver::class.java).apply {
                    action = ACTION_WIDGET_TAP
                }
                val pendingIntent = android.app.PendingIntent.getBroadcast(
                    context, id, intent,
                    android.app.PendingIntent.FLAG_UPDATE_CURRENT or android.app.PendingIntent.FLAG_IMMUTABLE
                )
                views.setOnClickPendingIntent(R.id.widget_root, pendingIntent)
                appWidgetManager.updateAppWidget(id, views)
            }
        }
    }
}
