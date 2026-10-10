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
        engine(this)
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
                        val ours = stamp == clipStamp && (label == null || label == "Ласточка")
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
