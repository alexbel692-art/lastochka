package app.lastochka.lastochka

import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.view.WindowManager
import io.flutter.embedding.android.FlutterFragmentActivity

// FragmentActivity — нужна для входа по отпечатку/лицу (код-пароль)
class MainActivity : FlutterFragmentActivity() {
    // окно подключается к уже работающей Ласточке (общий движок из кэша), а при закрытии окна она
    // продолжает работать. Движок именно «из кэша», а не «свой»: тогда, если система всё же создаст
    // второе окно, первое спокойно отдаст ему движок, а не уронит приложение
    override fun getCachedEngineId(): String {
        MainApplication.engine(application)
        return MainApplication.ENGINE_ID
    }
    override fun shouldDestroyEngineWithHost(): Boolean = false

    override fun onCreate(savedInstanceState: Bundle?) {
        // движок должен быть в кэше до того, как окно создаст свою часть Flutter
        MainApplication.engine(application)
        super.onCreate(savedInstanceState)
        current = this
        applyCallMode()
        applySecure()
        if (savedInstanceState == null) MainApplication.forwardTap(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        MainApplication.forwardTap(intent)
    }

    override fun onResume() {
        super.onResume()
        resumed = true
        applyCallMode()
        // обновление ждёт подтверждения — показываем системное окно «Обновить»
        SelfUpdate.showPending(this)
        // окно открыто — можно «повысить» фоновую службу до доступа к микрофону для звонков
        SyncService.startIfEnabled(this)
    }

    override fun onPause() {
        resumed = false
        super.onPause()
    }

    override fun onDestroy() {
        if (current === this) current = null
        super.onDestroy()
    }

    /** Запрет снимков экрана и превью в «недавних» (настройка «Запретить снимки экрана»). */
    fun applySecure() {
        // до Android 13 спрятать переписку из «недавних» можно только запретом снимков экрана
        val flag = secure || (hideRecents && Build.VERSION.SDK_INT < 33)
        if (flag) window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        else window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
        // при код-пароле снимок для «недавних приложений» не делается, даже если снимки экрана разрешены
        if (Build.VERSION.SDK_INT >= 33) setRecentsScreenshotEnabled(!(secure || hideRecents))
    }

    private var appliedCallMode: Boolean? = null

    /**
     * Флаги окна меняем не посреди кадра, а после него и только если они действительно меняются:
     * на Android 15 (One UI 7) смена «поверх блокировки» во время отрисовки перестраивает окно,
     * и экран конца звонка застывал недорисованным.
     */
    fun applyCallModeLater() {
        val v = window?.decorView ?: return
        v.post {
            if (isFinishing || isDestroyed) return@post
            if (!applyCallMode()) return@post
            // окно перестроится — через мгновение просим Flutter перерисовать кадр целиком
            v.postDelayed({ MainApplication.redraw() }, 250)
            v.postDelayed({ MainApplication.redraw() }, 900)
        }
    }

    /** Поверх экрана блокировки — только во время входящего звонка, а не всегда. */
    fun applyCallMode(): Boolean {
        if (appliedCallMode == callMode) return false
        appliedCallMode = callMode
        if (Build.VERSION.SDK_INT >= 27) {
            setShowWhenLocked(callMode)
            setTurnScreenOn(callMode)
        } else {
            @Suppress("DEPRECATION")
            val f = WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON
            if (callMode) window.addFlags(f) else window.clearFlags(f)
        }
        return true
    }

    companion object {
        var current: MainActivity? = null
        var callMode = false
        var resumed = false
        var secure = false
        var hideRecents = false
    }
}
