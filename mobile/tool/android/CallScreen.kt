package app.lastochka.lastochka

import android.app.Activity
import android.app.KeyguardManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.view.Gravity
import android.view.WindowManager
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView

/**
 * Входящий звонок на заблокированном телефоне — ОТДЕЛЬНОЕ окно, как в Telegram, WhatsApp и Element.
 *
 * Раньше «поверх блокировки» включалось у главного окна Ласточки, а после звонка выключалось. На Android 15
 * (One UI 7) каждое такое переключение перестраивает окно вместе с картинкой Flutter — и экран после звонка
 * застывал «наполовину». Теперь главное окно свои настройки никогда не меняет: поверх блокировки показывается
 * только это маленькое окно (обычные элементы Android, без Flutter), а после звонка оно просто закрывается.
 */
object CallScreen {
    private const val CHANNEL = "calls_v2"
    const val NOTIFICATION_ID = 7301

    @Volatile var callId: String? = null
    @Volatile var name: String = ""
    @Volatile var video = false
    @Volatile var payload: String = ""
    /** ringing — звонит, active — идёт разговор (с отметкой времени начала), ended — закончен. */
    @Volatile var state: String = "ringing"
    @Volatile var startedAt = 0L

    private fun channel(ctx: Context) {
        if (Build.VERSION.SDK_INT < 26) return
        val nm = ctx.getSystemService(NotificationManager::class.java)
        if (nm.getNotificationChannel(CHANNEL) != null) return
        // мелодию играет само приложение — у канала звука нет
        val ch = NotificationChannel(CHANNEL, "Звонки", NotificationManager.IMPORTANCE_HIGH)
        ch.description = "Входящие звонки"
        ch.setSound(null, null)
        ch.enableVibration(false)
        ch.lockscreenVisibility = Notification.VISIBILITY_PUBLIC
        nm.createNotificationChannel(ch)
    }

    private val pendingFlags = PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE

    /** Открыть Ласточку (её же окно), передав действие уведомления — как нажатие на обычное уведомление. */
    fun openAppIntent(ctx: Context, action: String, payload: String): Intent =
        Intent(ctx, MainActivity::class.java)
            .setAction("SELECT_NOTIFICATION")
            .putExtra("actionId", action)
            .putExtra("payload", payload)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)

    fun show(ctx: Context, id: String, who: String, isVideo: Boolean, tapPayload: String) {
        callId = id
        name = who
        video = isVideo
        payload = tapPayload
        state = "ringing"
        startedAt = 0L
        channel(ctx)
        val full = PendingIntent.getActivity(ctx, 11, Intent(ctx, CallLockActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK), pendingFlags)
        val open = PendingIntent.getActivity(ctx, 12, openAppIntent(ctx, "", tapPayload), pendingFlags)
        val answer = PendingIntent.getActivity(ctx, 13, openAppIntent(ctx, "answer", tapPayload), pendingFlags)
        val decline = PendingIntent.getBroadcast(
            ctx, 14,
            Intent(ctx, CallActionReceiver::class.java).putExtra("actionId", "decline").putExtra("payload", tapPayload),
            pendingFlags,
        )
        val b = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(ctx, CHANNEL) else @Suppress("DEPRECATION") Notification.Builder(ctx)
        b.setSmallIcon(ctx.resources.getIdentifier("ic_notification", "drawable", ctx.packageName))
            .setContentTitle(who)
            .setContentText(if (isVideo) "Входящий видеозвонок" else "Входящий звонок")
            .setCategory(Notification.CATEGORY_CALL)
            .setOngoing(true)
            .setAutoCancel(false)
            .setVisibility(Notification.VISIBILITY_PUBLIC)
            .setColor(0xFF43A047.toInt())
            .setContentIntent(open)
            .setFullScreenIntent(full, true)
            .addAction(Notification.Action.Builder(null as android.graphics.drawable.Icon?, "Отклонить", decline).build())
            .addAction(Notification.Action.Builder(null as android.graphics.drawable.Icon?, "Ответить", answer).build())
        if (Build.VERSION.SDK_INT < 26) {
            @Suppress("DEPRECATION")
            b.setPriority(Notification.PRIORITY_MAX)
        }
        if (Build.VERSION.SDK_INT >= 26) b.setTimeoutAfter(60_000)
        try {
            ctx.getSystemService(NotificationManager::class.java).notify(NOTIFICATION_ID, b.build())
        } catch (_: Throwable) {}
    }

    fun cancel(ctx: Context) {
        try {
            ctx.getSystemService(NotificationManager::class.java).cancel(NOTIFICATION_ID)
        } catch (_: Throwable) {}
    }

    /** Состояние звонка из Dart: active — соединились, ended — закончен. */
    fun update(ctx: Context, id: String, st: String) {
        if (id != callId) return
        state = st
        if (st == "active" && startedAt == 0L) startedAt = SystemClock.elapsedRealtime()
        if (st != "ringing") cancel(ctx)
        CallLockActivity.current?.refresh()
        if (st == "ended") callId = null
    }
}

/** «Отклонить» в уведомлении — без открытия окна. Принимаются только собственные (явные) намерения. */
class CallActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val action = intent.getStringExtra("actionId") ?: return
        val payload = intent.getStringExtra("payload") ?: return
        MainApplication.sendTap(action, payload)
        CallScreen.cancel(context)
    }
}

/** Окно звонка поверх экрана блокировки. Обычные элементы Android, без Flutter. */
class CallLockActivity : Activity() {
    private lateinit var status: TextView
    private lateinit var buttons: LinearLayout
    private val ui = Handler(Looper.getMainLooper())
    private val tick = object : Runnable {
        override fun run() {
            refresh()
            ui.postDelayed(this, 1000)
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // поверх блокировки и с включением экрана — только ЭТО окно, и только пока оно открыто
        if (Build.VERSION.SDK_INT >= 27) {
            setShowWhenLocked(true)
            setTurnScreenOn(true)
        } else {
            @Suppress("DEPRECATION")
            window.addFlags(WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON)
        }
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        // в окне видно, кто звонит, — снимок для «недавних» не нужен
        window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        val km = getSystemService(Context.KEYGUARD_SERVICE) as KeyguardManager
        if (CallScreen.callId == null) {
            finish()
            return
        }
        if (!km.isKeyguardLocked) {
            // телефон не заблокирован — звонок показывает обычный экран Ласточки
            startActivity(CallScreen.openAppIntent(this, "", CallScreen.payload))
            finish()
            return
        }
        current = this
        setContentView(build())
        refresh()
        ui.post(tick)
    }

    override fun onDestroy() {
        ui.removeCallbacks(tick)
        if (current === this) current = null
        super.onDestroy()
    }

    private fun dp(v: Int) = (v * resources.displayMetrics.density).toInt()

    private fun roundButton(text: String, color: Int, onClick: () -> Unit) = Button(this).apply {
        this.text = text
        setTextColor(Color.WHITE)
        textSize = 16f
        isAllCaps = false
        background = GradientDrawable().apply {
            cornerRadius = dp(28).toFloat()
            setColor(color)
        }
        setPadding(dp(24), dp(14), dp(24), dp(14))
        setOnClickListener { onClick() }
        layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f).apply {
            setMargins(dp(10), 0, dp(10), 0)
        }
    }

    private fun build(): LinearLayout {
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER_HORIZONTAL
            setBackgroundColor(0xFF15171C.toInt())
            setPadding(dp(24), dp(96), dp(24), dp(64))
        }
        val initial = TextView(this).apply {
            text = CallScreen.name.trim().firstOrNull()?.uppercase() ?: "?"
            setTextColor(Color.WHITE)
            textSize = 40f
            typeface = Typeface.DEFAULT_BOLD
            gravity = Gravity.CENTER
            background = GradientDrawable().apply {
                shape = GradientDrawable.OVAL
                setColor(0xFF5B6BF0.toInt())
            }
            layoutParams = LinearLayout.LayoutParams(dp(112), dp(112))
        }
        val title = TextView(this).apply {
            text = CallScreen.name
            setTextColor(Color.WHITE)
            textSize = 26f
            typeface = Typeface.DEFAULT_BOLD
            gravity = Gravity.CENTER
            setPadding(0, dp(24), 0, dp(8))
        }
        status = TextView(this).apply {
            setTextColor(0xFFB8BCC8.toInt())
            textSize = 16f
            gravity = Gravity.CENTER
        }
        val spacer = android.view.View(this).apply { layoutParams = LinearLayout.LayoutParams(1, 0, 1f) }
        buttons = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER
        }
        root.addView(initial)
        root.addView(title)
        root.addView(status)
        root.addView(spacer)
        root.addView(buttons)
        return root
    }

    private var shown = ""

    fun refresh() {
        val st = CallScreen.state
        if (st == "ended" || CallScreen.callId == null && st != "active") {
            finish()
            return
        }
        status.text = when (st) {
            "active" -> {
                val s = (SystemClock.elapsedRealtime() - CallScreen.startedAt) / 1000
                "Идёт разговор · %d:%02d".format(s / 60, s % 60)
            }
            else -> if (CallScreen.video) "Входящий видеозвонок" else "Входящий звонок"
        }
        if (shown == st) return
        shown = st
        buttons.removeAllViews()
        val payload = CallScreen.payload
        if (st == "active") {
            buttons.addView(roundButton("Завершить", 0xFFE53935.toInt()) {
                MainApplication.sendTap("hangup", payload)
            })
            buttons.addView(roundButton("Открыть", 0xFF3C4150.toInt()) { unlockAndOpen(payload) })
        } else {
            buttons.addView(roundButton("Отклонить", 0xFFE53935.toInt()) {
                MainApplication.sendTap("decline", payload)
                CallScreen.cancel(this)
                finish()
            })
            // ответ — прямо здесь, без разблокировки (только голос); экран Ласточки — после разблокировки
            buttons.addView(roundButton("Ответить", 0xFF43A047.toInt()) {
                MainApplication.sendTap("answer_locked", payload)
                CallScreen.cancel(this)
            })
        }
    }

    private fun unlockAndOpen(payload: String) {
        val km = getSystemService(Context.KEYGUARD_SERVICE) as KeyguardManager
        if (Build.VERSION.SDK_INT >= 26) {
            km.requestDismissKeyguard(this, object : KeyguardManager.KeyguardDismissCallback() {
                override fun onDismissSucceeded() {
                    startActivity(CallScreen.openAppIntent(this@CallLockActivity, "", payload))
                    finish()
                }
            })
        } else {
            startActivity(CallScreen.openAppIntent(this, "", payload))
            finish()
        }
    }

    companion object {
        @Volatile var current: CallLockActivity? = null
    }
}
