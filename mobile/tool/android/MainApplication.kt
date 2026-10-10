package app.lastochka.lastochka

import android.app.Application
import android.content.ClipData
import android.content.ClipDescription
import android.content.ClipboardManager
import android.os.Build
import android.os.PersistableBundle
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.PowerManager
import android.provider.Settings
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel

/**
 * Ласточка работает в одном «движке» Flutter, который живёт, пока жив процесс:
 * окно можно закрыть, а связь с сервером, уведомления и звонки продолжают работать
 * (процесс держит фоновая служба SyncService).
 */
class MainApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        startWatchdog()
        engine(this)
    }

    /**
     * Сторож главного потока: если он не отвечает 4 секунды (приложение «зависло»), записываем,
     * чем он занят, в файл — после перезапуска это попадёт в «Отчёт для диагностики».
     */
    private fun startWatchdog() {
        val main = android.os.Handler(mainLooper)
        val file = java.io.File(filesDir, "anr_trace.txt")
        Thread({
            var reported = false
            while (true) {
                val done = java.util.concurrent.atomic.AtomicBoolean(false)
                main.post { done.set(true) }
                Thread.sleep(4000)
                if (!done.get()) {
                    if (!reported) {
                        reported = true
                        try {
                            val sb = StringBuilder()
                            sb.append("Главный поток не отвечает > 4 с (").append(java.util.Date()).append(")\n")
                            for (el in mainLooper.thread.stackTrace.take(40)) sb.append("  at ").append(el.toString()).append('\n')
                            // потоки звонков и звука — часто держат главный поток
                            for ((t, st) in Thread.getAllStackTraces()) {
                                val n = t.name.lowercase()
                                if (n.contains("webrtc") || n.contains("audio") || n.contains("signal") || n.contains("worker")) {
                                    sb.append("— поток ").append(t.name).append(" (").append(t.state).append(")\n")
                                    for (el in st.take(12)) sb.append("    at ").append(el.toString()).append('\n')
                                }
                            }
                            file.writeText(sb.toString())
                        } catch (_: Throwable) {}
                    }
                } else {
                    reported = false
                }
            }
        }, "lastochka-watchdog").apply { isDaemon = true; start() }
    }

    companion object {
        private const val ID = "lastochka"

        fun engine(app: Application): FlutterEngine {
            FlutterEngineCache.getInstance().get(ID)?.let { return it }
            val e = FlutterEngine(app)
            channel(app, e)
            e.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint.createDefault())
            FlutterEngineCache.getInstance().put(ID, e)
            return e
        }

        private var channel: MethodChannel? = null
        private var dartReady = false
        private var clipStamp = 0L
        private val pendingTaps = mutableListOf<Map<String, String>>()

        /** Нажатие на уведомление: передать в Dart (если Ласточка ещё запускается — после готовности). */
        fun forwardTap(intent: Intent?) {
            val a = intent?.action ?: return
            if (a != "SELECT_NOTIFICATION" && a != "SELECT_FOREGROUND_NOTIFICATION") return
            val tap = mapOf("action" to (intent.getStringExtra("actionId") ?: ""), "payload" to (intent.getStringExtra("payload") ?: ""))
            if (dartReady) channel?.invokeMethod("notificationTap", tap) else pendingTaps.add(tap)
        }

        private fun channel(ctx: Context, e: FlutterEngine) {
            val ch = MethodChannel(e.dartExecutor.binaryMessenger, "lastochka/system")
            channel = ch
            ch.setMethodCallHandler { call, result ->
                when (call.method) {
                    "ready" -> {
                        dartReady = true
                        pendingTaps.forEach { ch.invokeMethod("notificationTap", it) }
                        pendingTaps.clear()
                        result.success(true)
                    }
                    "secure" -> {
                        MainActivity.secure = call.arguments == true
                        MainActivity.current?.applySecure()
                        result.success(true)
                    }
                    "callMode" -> {
                        MainActivity.callMode = call.arguments == true
                        MainActivity.current?.applyCallMode()
                        result.success(true)
                    }
                    "tone" -> { Tones.play(ctx, call.arguments as? String ?: ""); result.success(true) }
                    "toneStop" -> { Tones.stop(ctx); result.success(true) }
                    "copySensitive" -> {
                        // текст помечается секретным: Android 13+ не показывает его в подсказках и превью
                        val cm = ctx.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                        val clip = ClipData.newPlainText("Ласточка", call.arguments as? String ?: "")
                        if (Build.VERSION.SDK_INT >= 24) {
                            clip.description.extras = PersistableBundle().apply {
                                putBoolean(if (Build.VERSION.SDK_INT >= 33) ClipDescription.EXTRA_IS_SENSITIVE else "android.content.extra.IS_SENSITIVE", true)
                            }
                        }
                        cm.setPrimaryClip(clip)
                        clipStamp = System.currentTimeMillis()
                        result.success(clipStamp)
                    }
                    "clearClip" -> {
                        // очищаем, только если в буфере всё ещё наш текст (никто ничего не копировал после)
                        val cm = ctx.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                        val stamp = (call.arguments as? Number)?.toLong() ?: 0L
                        val label = cm.primaryClipDescription?.label?.toString()
                        val ours = stamp == clipStamp && label == "Ласточка"
                        if (ours) {
                            if (Build.VERSION.SDK_INT >= 28) cm.clearPrimaryClip() else cm.setPrimaryClip(ClipData.newPlainText("", ""))
                        }
                        result.success(ours)
                    }
                    "startService" -> { SyncService.start(ctx); result.success(true) }
                    "stopService" -> { ctx.stopService(Intent(ctx, SyncService::class.java)); result.success(true) }
                    "isIgnoringBattery" -> {
                        val pm = ctx.getSystemService(Context.POWER_SERVICE) as PowerManager
                        result.success(pm.isIgnoringBatteryOptimizations(ctx.packageName))
                    }
                    "requestIgnoreBattery" -> {
                        try {
                            ctx.startActivity(Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, Uri.parse("package:" + ctx.packageName)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                            result.success(true)
                        } catch (_: Exception) {
                            result.success(false)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
        }
    }
}


/**
 * Звуки звонка средствами Android: входящий — мелодия звонка телефона (с вибрацией по настройкам),
 * исходящий — системные гудки, конец — короткий сигнал. Надёжнее стороннего проигрывателя:
 * не конфликтует с модулем звонков и гарантированно останавливается.
 */
object Tones {
    private var ringtone: android.media.Ringtone? = null
    private var tone: android.media.ToneGenerator? = null
    private var vibrating = false
    private val handler = android.os.Handler(android.os.Looper.getMainLooper())
    private val keepRinging = object : Runnable {
        override fun run() {
            val r = ringtone ?: return
            // до Android 9 мелодия не повторяется сама
            try { if (!r.isPlaying) r.play() } catch (_: Throwable) {}
            handler.postDelayed(this, 1500)
        }
    }

    fun stop(ctx: Context) {
        handler.removeCallbacks(keepRinging)
        try { ringtone?.stop() } catch (_: Throwable) {}
        ringtone = null
        try { tone?.stopTone(); tone?.release() } catch (_: Throwable) {}
        tone = null
        if (vibrating) {
            try { (ctx.getSystemService(Context.VIBRATOR_SERVICE) as android.os.Vibrator).cancel() } catch (_: Throwable) {}
            vibrating = false
        }
    }

    fun play(ctx: Context, kind: String) {
        stop(ctx)
        try {
            when (kind) {
                "incoming" -> {
                    val am = ctx.getSystemService(Context.AUDIO_SERVICE) as android.media.AudioManager
                    if (am.ringerMode == android.media.AudioManager.RINGER_MODE_NORMAL) {
                        val uri = android.media.RingtoneManager.getActualDefaultRingtoneUri(ctx, android.media.RingtoneManager.TYPE_RINGTONE)
                            ?: android.media.RingtoneManager.getDefaultUri(android.media.RingtoneManager.TYPE_RINGTONE)
                        ringtone = android.media.RingtoneManager.getRingtone(ctx, uri)?.also { r ->
                            r.audioAttributes = android.media.AudioAttributes.Builder()
                                .setUsage(android.media.AudioAttributes.USAGE_NOTIFICATION_RINGTONE)
                                .setContentType(android.media.AudioAttributes.CONTENT_TYPE_SONIFICATION).build()
                            if (Build.VERSION.SDK_INT >= 28) r.isLooping = true
                            r.play()
                            handler.postDelayed(keepRinging, 1500)
                        }
                    }
                    if (am.ringerMode != android.media.AudioManager.RINGER_MODE_SILENT) {
                        val v = ctx.getSystemService(Context.VIBRATOR_SERVICE) as android.os.Vibrator
                        val pattern = longArrayOf(0, 800, 1200)
                        if (Build.VERSION.SDK_INT >= 26) v.vibrate(android.os.VibrationEffect.createWaveform(pattern, 0))
                        else { @Suppress("DEPRECATION") v.vibrate(pattern, 0) }
                        vibrating = true
                    }
                }
                "outgoing" -> {
                    tone = android.media.ToneGenerator(android.media.AudioManager.STREAM_VOICE_CALL, 70).also {
                        it.startTone(android.media.ToneGenerator.TONE_SUP_RINGTONE)
                    }
                }
                "hangup" -> {
                    val tg = android.media.ToneGenerator(android.media.AudioManager.STREAM_VOICE_CALL, 70)
                    tg.startTone(android.media.ToneGenerator.TONE_PROP_ACK, 400)
                    handler.postDelayed({ try { tg.release() } catch (_: Throwable) {} }, 700)
                }
            }
        } catch (_: Throwable) {}
    }
}
