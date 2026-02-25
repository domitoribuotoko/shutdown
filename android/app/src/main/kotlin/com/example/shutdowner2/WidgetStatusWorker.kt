package com.example.shutdowner2

import androidx.work.CoroutineWorker
import androidx.work.WorkerParameters
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * Проверяет доступность ПК по TCP и обновляет виджет.
 * Использует общий WidgetStatusChecker; при необходимости следующей проверки
 * планирует её через AlarmManager (чтобы работало при закрытом приложении).
 */
class WidgetStatusWorker(
    context: android.content.Context,
    params: WorkerParameters
) : CoroutineWorker(context, params) {

    override suspend fun doWork(): Result = withContext(Dispatchers.IO) {
        val delaySec = WidgetStatusChecker.runCheck(applicationContext)
        if (delaySec >= 0) {
            WidgetStatusAlarmReceiver.scheduleNextCheck(applicationContext, delaySec)
        }
        Result.success()
    }
}
