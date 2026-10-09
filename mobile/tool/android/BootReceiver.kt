package app.lastochka.lastochka

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/** После перезагрузки телефона или обновления приложения — снова на связи. */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        SyncService.startIfEnabled(context)
    }
}
