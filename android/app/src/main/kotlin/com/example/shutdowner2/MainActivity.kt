package com.example.shutdowner2

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.android.FlutterActivity
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.TimeUnit

class MainActivity : FlutterActivity() {

    private var widgetSyncReceiver: BroadcastReceiver? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        WidgetSyncBridge.channel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            WidgetSyncBridge.CHANNEL_NAME
        )
    }

    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        super.onCreate(savedInstanceState)
        scheduleStatusCheck()
        widgetSyncReceiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context?, intent: Intent?) {
                WidgetSyncBridge.notifyWidgetTapped()
            }
        }
        val filter = IntentFilter(WidgetSyncBridge.ACTION_WIDGET_TAPPED_SYNC)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(widgetSyncReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            @Suppress("UnspecifiedRegisterReceiverFlag")
            registerReceiver(widgetSyncReceiver, filter)
        }
    }

    override fun onDestroy() {
        widgetSyncReceiver?.let { unregisterReceiver(it) }
        widgetSyncReceiver = null
        WidgetSyncBridge.channel = null
        super.onDestroy()
    }

    private fun scheduleStatusCheck() {
        val request = PeriodicWorkRequestBuilder<WidgetStatusWorker>(15, TimeUnit.MINUTES).build()
        WorkManager.getInstance(this).enqueueUniquePeriodicWork(
            "widget_pc_status",
            ExistingPeriodicWorkPolicy.KEEP,
            request
        )
    }
}
