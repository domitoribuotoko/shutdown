package com.example.shutdowner2

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.content.Intent
import android.view.View
import android.widget.RemoteViews
import android.util.Log
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import com.example.shutdowner2.R
import java.util.concurrent.TimeUnit

class HomeWidgetProvider : AppWidgetProvider() {

    override fun onEnabled(context: Context) {
        super.onEnabled(context)
        // Периодическая проверка статуса ПК, чтобы виджет показывал реальное состояние
        val request = PeriodicWorkRequestBuilder<WidgetStatusWorker>(15, TimeUnit.MINUTES).build()
        WorkManager.getInstance(context).enqueueUniquePeriodicWork(
            "widget_pc_status",
            ExistingPeriodicWorkPolicy.KEEP,
            request
        )
        Log.d("PC_WIDGET", "Periodic status check scheduled (every 15 min)")
    }

    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray
    ) {
        val prefs = context.getSharedPreferences("HomeWidgetPreferences", Context.MODE_PRIVATE)
        val status = prefs.getString("pc_status", "off") ?: "off"
        val (bgResId, iconResId, pending) = when (status) {
            "on" -> Triple(R.drawable.widget_circle_on, R.drawable.ic_widget_power_on, false)
            "off" -> Triple(R.drawable.widget_circle_off, R.drawable.ic_widget_power_off, false)
            "pending_wol", "pending_shutdown" -> Triple(R.drawable.widget_circle_white, 0, true)
            else -> Triple(R.drawable.widget_circle_white, 0, true)
        }
        Log.d("PC_WIDGET", "onUpdate: status=$status")

        for (appWidgetId in appWidgetIds) {
            val views = RemoteViews(context.packageName, R.layout.home_widget_layout)
            views.setInt(R.id.widget_circle_bg, "setBackgroundResource", bgResId)
            views.setViewVisibility(R.id.widget_icon, if (pending) View.GONE else View.VISIBLE)
            views.setViewVisibility(R.id.widget_progress, if (pending) View.VISIBLE else View.GONE)
            if (!pending) views.setImageViewResource(R.id.widget_icon, iconResId)

            val tapIntent = Intent(context, WidgetActionReceiver::class.java).apply {
                action = WidgetActionReceiver.ACTION_WIDGET_TAP
            }
            val pendingIntent = PendingIntent.getBroadcast(
                context,
                appWidgetId,
                tapIntent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
            views.setOnClickPendingIntent(R.id.widget_root, pendingIntent)

            appWidgetManager.updateAppWidget(appWidgetId, views)
        }
    }
}