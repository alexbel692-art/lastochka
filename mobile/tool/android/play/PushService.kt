package app.lastochka.lastochka

import android.content.Context
import com.google.firebase.messaging.FirebaseMessaging
import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * Уведомления через Google (только версия из Google Play).
 * Сервер Matrix → шлюз уведомлений → Firebase → сюда. В «толчке» только номер события, без текста:
 * Ласточка просыпается, сама забирает сообщения с сервера и показывает уведомление или звонок.
 */
class PushService : FirebaseMessagingService() {
    override fun onMessageReceived(message: RemoteMessage) {
        val done = CountDownLatch(1)
        MainApplication.pushLatch = done
        MainApplication.push(application)
        // держим процесс, пока Ласточка забирает новые события (Google даёт на это несколько секунд)
        try { done.await(9, TimeUnit.SECONDS) } catch (_: InterruptedException) {}
    }

    override fun onNewToken(token: String) {
        MainApplication.pushToken(token)
    }

    companion object {
        @JvmStatic
        fun token(ctx: Context, cb: Function1<String?, Unit>) {
            try {
                FirebaseMessaging.getInstance().token.addOnCompleteListener { cb(if (it.isSuccessful) it.result else null) }
            } catch (_: Throwable) {
                cb(null)
            }
        }
    }
}
