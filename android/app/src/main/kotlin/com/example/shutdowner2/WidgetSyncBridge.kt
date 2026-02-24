package com.example.shutdowner2

import io.flutter.plugin.common.MethodChannel

/**
 * Мост для уведомления Flutter о нажатии на виджет (чтобы UI приложения синхронизировался).
 * Channel выставляется из MainActivity при конфигурации движка.
 */
object WidgetSyncBridge {
    var channel: MethodChannel? = null

    const val ACTION_WIDGET_TAPPED_SYNC = "com.example.shutdowner2.WIDGET_TAPPED_SYNC"
    const val CHANNEL_NAME = "com.example.shutdowner2/widget_sync"

    fun notifyWidgetTapped() {
        try {
            channel?.invokeMethod("widgetDidTap", null)
        } catch (_: Exception) { }
    }
}
