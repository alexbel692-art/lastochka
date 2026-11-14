package app.lastochka.lastochka

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder

/** Фоновая служба: держит Ласточку на связи с сервером (сообщения и звонки при закрытом приложении). */
class SyncService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        MainApplication.engine(application)
        val nm = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= 26) {
            nm.createNotificationChannel(NotificationChannel(CHANNEL, "Работа в фоне", NotificationManager.IMPORTANCE_MIN).apply {
                description = "Ласточка остаётся на связи, чтобы приходили сообщения и звонки"
                setShowBadge(false)
            })
        }
        // версия из Google Play: служба работает только во время звонка (микрофон в фоне),
        // сообщения будит Google (FCM) — постоянной фоновой службы там нет
        if (isPlay(this) && (checkSelfPermission(android.Manifest.permission.RECORD_AUDIO) != android.content.pm.PackageManager.PERMISSION_GRANTED || MainActivity.current == null)) {
            stopSelf()
            return START_NOT_STICKY
        }
        val open = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP), PendingIntent.FLAG_IMMUTABLE)
        val b = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(this, CHANNEL) else @Suppress("DEPRECATION") Notification.Builder(this)
        val n = b.setSmallIcon(R.drawable.ic_notification)
            .setContentTitle(if (isPlay(this)) "Идёт звонок" else "Ласточка на связи")
            .setContentText(if (isPlay(this)) "Разговор продолжается, когда Ласточка свёрнута" else "Сообщения и звонки придут, даже если закрыть приложение")
            .setOngoing(true)
            .setShowWhen(false)
            .setContentIntent(open)
            .build()
        // микрофон в фоне нужен, чтобы входящий звонок зазвонил при закрытой Ласточке;
        // такой тип разрешён, только когда служба запущена из открытого окна
        val mic = checkSelfPermission(android.Manifest.permission.RECORD_AUDIO) == android.content.pm.PackageManager.PERMISSION_GRANTED && MainActivity.current != null
        if (isPlay(this)) {
            if (Build.VERSION.SDK_INT >= 30) startForeground(1, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE) else startForeground(1, n)
            return START_NOT_STICKY
        }
        if (Build.VERSION.SDK_INT >= 34) {
            try {
                startForeground(1, n, if (mic) ServiceInfo.FOREGROUND_SERVICE_TYPE_REMOTE_MESSAGING or ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE else ServiceInfo.FOREGROUND_SERVICE_TYPE_REMOTE_MESSAGING)
            } catch (_: Exception) {
                startForeground(1, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_REMOTE_MESSAGING)
            }
        } else if (Build.VERSION.SDK_INT >= 30) {
            startForeground(1, n, if (mic) ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE else 0)
        } else {
            startForeground(1, n)
        }
        return START_STICKY
    }

    companion object {
        private const val CHANNEL = "background"

        /** Сборка для Google Play: ресурс lastochka_play кладёт туда только сборка AAB. */
        fun isPlay(ctx: Context): Boolean = try {
            val id = ctx.resources.getIdentifier("lastochka_play", "bool", ctx.packageName)
            id != 0 && ctx.resources.getBoolean(id)
        } catch (_: Throwable) { false }

        /** Запустить, если пользователь вошёл и не отключил работу в фоне. */
        fun startIfEnabled(ctx: Context) {
            if (isPlay(ctx)) return
            val prefs = ctx.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
            if (!prefs.getBoolean("flutter.bg.enabled", true) || !prefs.contains("flutter.bg.loggedIn")) return
            start(ctx)
        }
        fun start(ctx: Context) {
            val i = Intent(ctx, SyncService::class.java)
            try {
                if (Build.VERSION.SDK_INT >= 26) ctx.startForegroundService(i) else ctx.startService(i)
            } catch (_: Exception) {
            }
        }
    }
}
