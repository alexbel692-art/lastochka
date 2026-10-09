package app.lastochka.lastochka

import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.view.WindowManager
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine

// FragmentActivity — нужна для входа по отпечатку/лицу (код-пароль)
class MainActivity : FlutterFragmentActivity() {
    // окно подключается к уже работающей Ласточке, а при закрытии окна она продолжает работать
    override fun provideFlutterEngine(context: Context): FlutterEngine = MainApplication.engine(application)
    override fun shouldDestroyEngineWithHost(): Boolean = false

    override fun onCreate(savedInstanceState: Bundle?) {
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
        applyCallMode()
        // окно открыто — можно «повысить» фоновую службу до доступа к микрофону для звонков
        SyncService.startIfEnabled(this)
    }

    override fun onDestroy() {
        if (current === this) current = null
        super.onDestroy()
    }

    /** Запрет снимков экрана и превью в «недавних» (настройка «Запретить снимки экрана»). */
    fun applySecure() {
        if (secure) window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        else window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
    }

    /** Поверх экрана блокировки — только во время входящего звонка, а не всегда. */
    fun applyCallMode() {
        if (Build.VERSION.SDK_INT >= 27) {
            setShowWhenLocked(callMode)
            setTurnScreenOn(callMode)
        } else {
            @Suppress("DEPRECATION")
            val f = WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON
            if (callMode) window.addFlags(f) else window.clearFlags(f)
        }
    }

    companion object {
        var current: MainActivity? = null
        var callMode = false
        var secure = false
    }
}
