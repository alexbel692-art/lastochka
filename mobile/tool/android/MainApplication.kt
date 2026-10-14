package app.lastochka.lastochka

import android.app.Application
import android.app.PendingIntent
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
        catchCrashes()
        startWatchdog()
        engine(this)
    }

    /** Падение системной части (Kotlin): записываем стек в файл, он попадёт в следующий отчёт. */
    private fun catchCrashes() {
        val prev = Thread.getDefaultUncaughtExceptionHandler()
        val file = java.io.File(filesDir, "native_crash.txt")
        Thread.setDefaultUncaughtExceptionHandler { t, e ->
            try {
                val sw = java.io.StringWriter()
                e.printStackTrace(java.io.PrintWriter(sw))
                val text = "поток ${t.name}, ${java.text.SimpleDateFormat("yyyy-MM-dd HH:mm:ss", java.util.Locale.US).format(java.util.Date())}\n" +
                    sw.toString().lines().take(40).joinToString("\n")
                file.writeText(text)
            } catch (_: Throwable) {}
            prev?.uncaughtException(t, e)
        }
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
        const val ENGINE_ID = ID

        fun engine(app: Application): FlutterEngine {
            FlutterEngineCache.getInstance().get(ID)?.let { cached ->
                // движок, который уже остановлен, не отдаём окну — иначе оно падает при первом же
                // изменении размера («FlutterJNI is not attached»); создаём новый
                if (cached.dartExecutor.isExecutingDart) return cached
                FlutterEngineCache.getInstance().remove(ID)
                channel = null
                dartReady = false
            }
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

        /** Состояние самообновления — в Dart. */
        fun installStatus(s: String) {
            android.os.Handler(android.os.Looper.getMainLooper()).post {
                try { channel?.invokeMethod("installStatus", s) } catch (_: Throwable) {}
            }
        }

        /** Попросить Flutter перерисовать кадр (после перестройки окна). */
        fun redraw() {
            try { channel?.invokeMethod("redraw", null) } catch (_: Throwable) {}
        }

        /** Действие из окна звонка или уведомления — в Dart (как нажатие на уведомление). */
        fun sendTap(action: String, payload: String) {
            val tap = mapOf("action" to action, "payload" to payload)
            android.os.Handler(android.os.Looper.getMainLooper()).post {
                if (dartReady) channel?.invokeMethod("notificationTap", tap) else pendingTaps.add(tap)
            }
        }

        /** Нажатие на уведомление: передать в Dart (если Ласточка ещё запускается — после готовности). */
        fun forwardTap(intent: Intent?) {
            val a = intent?.action ?: return
            if (a != "SELECT_NOTIFICATION" && a != "SELECT_FOREGROUND_NOTIFICATION") return
            val tap = mapOf("action" to (intent.getStringExtra("actionId") ?: ""), "payload" to (intent.getStringExtra("payload") ?: ""))
            if (dartReady) channel?.invokeMethod("notificationTap", tap) else pendingTaps.add(tap)
        }

        private var netWatched = false
        private var lastNet: android.net.Network? = null

        /** Смена сети (Wi-Fi ↔ мобильный интернет): сообщаем в Dart — звонок переподключится, не обрываясь. */
        private fun watchNetwork(ctx: Context) {
            if (netWatched || Build.VERSION.SDK_INT < 24) return
            netWatched = true
            try {
                val cm = ctx.getSystemService(Context.CONNECTIVITY_SERVICE) as android.net.ConnectivityManager
                cm.registerDefaultNetworkCallback(object : android.net.ConnectivityManager.NetworkCallback() {
                    override fun onAvailable(network: android.net.Network) {
                        val changed = lastNet != null && lastNet != network
                        lastNet = network
                        if (changed) android.os.Handler(android.os.Looper.getMainLooper()).post { channel?.invokeMethod("networkChanged", null) }
                    }
                })
            } catch (_: Throwable) {}
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
                        watchNetwork(ctx)
                        result.success(true)
                    }
                    "secure" -> {
                        MainActivity.secure = call.arguments == true
                        MainActivity.current?.applySecure()
                        result.success(true)
                    }
                    "hideRecents" -> {
                        MainActivity.hideRecents = call.arguments == true
                        MainActivity.current?.applySecure()
                        result.success(true)
                    }
                    // входящий звонок: уведомление и окно поверх блокировки — отдельное (CallScreen.kt)
                    "showCall" -> {
                        CallScreen.show(ctx, call.argument<String>("callId") ?: "", call.argument<String>("name") ?: "",
                            call.argument<Boolean>("video") == true, call.argument<String>("payload") ?: "")
                        result.success(true)
                    }
                    "cancelCall" -> { CallScreen.cancel(ctx); result.success(true) }
                    "callUi" -> {
                        CallScreen.update(ctx, call.argument<String>("callId") ?: "", call.argument<String>("state") ?: "")
                        result.success(true)
                    }
                    "callMode" -> {
                        // ответ — сразу, а флаги окна меняются после текущего кадра (см. applyCallMode)
                        MainActivity.callMode = call.arguments == true
                        result.success(true)
                        MainActivity.current?.applyCallModeLater()
                    }
                    // звуки — в отдельном потоке: системный генератор тонов и мелодия звонка
                    // обращаются к звуковой службе и на некоторых телефонах отвечают сотни миллисекунд
                    "tone" -> { val k = call.arguments as? String ?: ""; Tones.post { Tones.play(ctx, k) }; result.success(true) }
                    "toneStop" -> { Tones.post { Tones.stop(ctx) }; result.success(true) }
                    "keyguardLocked" -> {
                        val km = ctx.getSystemService(Context.KEYGUARD_SERVICE) as android.app.KeyguardManager
                        result.success(km.isKeyguardLocked)
                    }
                    // самообновление через системный установщик (Android 12+ — без вопросов, если разрешено)
                    "installApk" -> SelfUpdate.install(ctx, call.arguments as? String ?: "") { result.success(it) }
                    "compressVideo" -> {
                        // сжатие видео перед отправкой (Media3 Transformer, аппаратный кодировщик)
                        try {
                            VideoCompress.start(ctx, call.argument<String>("src") ?: "", call.argument<String>("dst") ?: "",
                                call.argument<Int>("short") ?: 720, call.argument<Int>("bitrate") ?: 2_500_000) { ok -> result.success(ok) }
                        } catch (_: Throwable) {
                            result.success(false)
                        }
                    }
                    "compressProgress" -> result.success(VideoCompress.progress())
                    // какие процессоры поддерживает телефон (а не в каком режиме запущено приложение)
                    "abis" -> result.success(Build.SUPPORTED_ABIS.toList())
                    "uptime" -> {
                        // время с включения телефона: его нельзя «перевести», в отличие от часов
                        val boot = if (Build.VERSION.SDK_INT >= 24) Settings.Global.getInt(ctx.contentResolver, Settings.Global.BOOT_COUNT, -1) else -1
                        result.success(mapOf("boot" to boot, "ms" to android.os.SystemClock.elapsedRealtime()))
                    }
                    "videoFrame" -> {
                        // кадр из видео для превью (как в Telegram); делается в фоне, чтобы не подвешивать экран
                        val path = call.argument<String>("path") ?: ""
                        val max = call.argument<Int>("max") ?: 480
                        Thread({
                            val r = try { VideoFrame.grab(path, max) } catch (_: Throwable) { null }
                            android.os.Handler(android.os.Looper.getMainLooper()).post { result.success(r) }
                        }, "video-frame").start()
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
    private val thread = android.os.HandlerThread("lastochka-tones").apply { start() }
    private val handler = android.os.Handler(thread.looper)

    /** Всё про звук звонка — по очереди в своём потоке, не на главном (там рисуется экран). */
    fun post(f: () -> Unit) { handler.post { try { f() } catch (_: Throwable) {} } }
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

/** Первый кадр видео в JPEG (без каких-либо сведений из исходного файла) и размеры видео. */
object VideoFrame {
    fun grab(path: String, max: Int): Map<String, Any>? {
        val mr = android.media.MediaMetadataRetriever()
        try {
            mr.setDataSource(path)
            val rot = mr.extractMetadata(android.media.MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION)?.toIntOrNull() ?: 0
            var vw = mr.extractMetadata(android.media.MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)?.toIntOrNull() ?: 0
            var vh = mr.extractMetadata(android.media.MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)?.toIntOrNull() ?: 0
            if (rot == 90 || rot == 270) { val t = vw; vw = vh; vh = t }
            val dur = mr.extractMetadata(android.media.MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull() ?: 0L
            var bmp = mr.getFrameAtTime(0, android.media.MediaMetadataRetriever.OPTION_CLOSEST_SYNC) ?: return null
            // на части устройств кадр приходит неповёрнутым — поворачиваем сами
            if (vw > 0 && vh > 0 && (bmp.width > bmp.height) != (vw > vh) && (rot == 90 || rot == 270)) {
                val m = android.graphics.Matrix().apply { postRotate(rot.toFloat()) }
                bmp = android.graphics.Bitmap.createBitmap(bmp, 0, 0, bmp.width, bmp.height, m, true)
            }
            val scale = minOf(1f, max.toFloat() / maxOf(bmp.width, bmp.height))
            if (scale < 1f) {
                bmp = android.graphics.Bitmap.createScaledBitmap(bmp, (bmp.width * scale).toInt().coerceAtLeast(1), (bmp.height * scale).toInt().coerceAtLeast(1), true)
            }
            val out = java.io.ByteArrayOutputStream()
            bmp.compress(android.graphics.Bitmap.CompressFormat.JPEG, 82, out)
            if (vw <= 0 || vh <= 0) { vw = bmp.width; vh = bmp.height }
            return mapOf("jpeg" to out.toByteArray(), "w" to bmp.width, "h" to bmp.height, "vw" to vw, "vh" to vh, "duration" to dur)
        } finally {
            try { mr.release() } catch (_: Throwable) {}
        }
    }
}

/** Сжатие видео: короткая сторона до [short] точек, H.264 + AAC, без сведений из исходного файла. */
@androidx.annotation.OptIn(markerClass = [androidx.media3.common.util.UnstableApi::class])
object VideoCompress {
    private var current: androidx.media3.transformer.Transformer? = null

    fun start(ctx: Context, src: String, dst: String, short: Int, bitrate: Int, done: (Boolean) -> Unit) {
        // не увеличиваем видео, которое и так меньше нужного размера
        var shortSide = 0
        val mr = android.media.MediaMetadataRetriever()
        try {
            mr.setDataSource(src)
            val w = mr.extractMetadata(android.media.MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)?.toIntOrNull() ?: 0
            val h = mr.extractMetadata(android.media.MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)?.toIntOrNull() ?: 0
            shortSide = minOf(w, h)
        } catch (_: Throwable) {
        } finally {
            try { mr.release() } catch (_: Throwable) {}
        }
        val listener = object : androidx.media3.transformer.Transformer.Listener {
            override fun onCompleted(composition: androidx.media3.transformer.Composition, exportResult: androidx.media3.transformer.ExportResult) {
                current = null
                done(true)
            }
            override fun onError(composition: androidx.media3.transformer.Composition, exportResult: androidx.media3.transformer.ExportResult,
                                 exportException: androidx.media3.transformer.ExportException) {
                current = null
                done(false)
            }
        }
        val encoders = androidx.media3.transformer.DefaultEncoderFactory.Builder(ctx)
            .setRequestedVideoEncoderSettings(androidx.media3.transformer.VideoEncoderSettings.Builder().setBitrate(bitrate).build())
            .build()
        val t = androidx.media3.transformer.Transformer.Builder(ctx)
            .setVideoMimeType(androidx.media3.common.MimeTypes.VIDEO_H264)
            .setAudioMimeType(androidx.media3.common.MimeTypes.AUDIO_AAC)
            .setEncoderFactory(encoders)
            .addListener(listener)
            .build()
        val video = if (shortSide > short) listOf<androidx.media3.common.Effect>(androidx.media3.effect.Presentation.createForShortSide(short)) else emptyList()
        val item = androidx.media3.transformer.EditedMediaItem.Builder(androidx.media3.common.MediaItem.fromUri(Uri.fromFile(java.io.File(src))))
            .setEffects(androidx.media3.transformer.Effects(emptyList(), video))
            .build()
        current = t
        t.start(item, dst)
    }

    /** Готовность в процентах, -1 — сжатие не идёт. */
    fun progress(): Int {
        val t = current ?: return -1
        val h = androidx.media3.transformer.ProgressHolder()
        return if (t.getProgress(h) == androidx.media3.transformer.Transformer.PROGRESS_STATE_AVAILABLE) h.progress else 0
    }
}

/**
 * Самообновление: APK (уже проверенный по подписи разработчика в Dart) передаётся системному установщику.
 * Android 12+ разрешает приложению обновлять себя без вопросов; если система всё же просит подтвердить,
 * окно «Обновить» показывается сразу (Ласточка открыта) или при следующем открытии.
 */
object SelfUpdate {
    var pending: Intent? = null

    /** Ответ системного установщика. Приходит только через наш явный PendingIntent в неэкспортируемый приёмник. */
    fun onStatus(ctx: Context, intent: Intent) {
        run {
            when (val st = intent.getIntExtra(android.content.pm.PackageInstaller.EXTRA_STATUS, -999)) {
                android.content.pm.PackageInstaller.STATUS_PENDING_USER_ACTION -> {
                    val ask: Intent? = if (Build.VERSION.SDK_INT >= 33) intent.getParcelableExtra(Intent.EXTRA_INTENT, Intent::class.java)
                        else @Suppress("DEPRECATION") intent.getParcelableExtra(Intent.EXTRA_INTENT)
                    // запускаем только окно подтверждения установки системы и без выдачи доступа к файлам
                    if (ask != null && !isSystemInstaller(ctx, ask)) {
                        MainApplication.installStatus("fail:unexpected")
                        return
                    }
                    ask?.flags = (ask?.flags ?: 0) and (Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
                        Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION or Intent.FLAG_GRANT_PREFIX_URI_PERMISSION).inv()
                    ask?.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    val act = MainActivity.current
                    if (ask != null && act != null && MainActivity.resumed) {
                        try { act.startActivity(ask) } catch (_: Throwable) { pending = ask }
                    } else {
                        pending = ask
                    }
                    MainApplication.installStatus("pending")
                }
                android.content.pm.PackageInstaller.STATUS_SUCCESS -> MainApplication.installStatus("success")
                else -> MainApplication.installStatus("fail:$st:" + (intent.getStringExtra(android.content.pm.PackageInstaller.EXTRA_STATUS_MESSAGE) ?: ""))
            }
        }
    }

    /** Окно подтверждения от системного установщика. Сам приёмник неэкспортируемый — это вторая линия защиты. */
    private fun isSystemInstaller(@Suppress("UNUSED_PARAMETER") ctx: Context, i: Intent): Boolean =
        i.action?.startsWith("android.content.pm.action.CONFIRM_") == true

    /** Открыли Ласточку — показать отложенное окно установки. */
    fun showPending(act: android.app.Activity) {
        val i = pending ?: return
        pending = null
        try { act.startActivity(i) } catch (_: Throwable) {}
    }

    fun install(ctx: Context, path: String, done: (String) -> Unit) {
        val main = android.os.Handler(android.os.Looper.getMainLooper())
        Thread({
            val r = try {
                val file = java.io.File(path)
                val pi = ctx.packageManager.packageInstaller
                val params = android.content.pm.PackageInstaller.SessionParams(android.content.pm.PackageInstaller.SessionParams.MODE_FULL_INSTALL)
                params.setAppPackageName(ctx.packageName)
                if (Build.VERSION.SDK_INT >= 31) params.setRequireUserAction(android.content.pm.PackageInstaller.SessionParams.USER_ACTION_NOT_REQUIRED)
                val id = pi.createSession(params)
                pi.openSession(id).use { s ->
                    file.inputStream().use { inp ->
                        s.openWrite("lastochka.apk", 0, file.length()).use { out ->
                            inp.copyTo(out)
                            s.fsync(out)
                        }
                    }
                    val flags = PendingIntent.FLAG_UPDATE_CURRENT or (if (Build.VERSION.SDK_INT >= 31) PendingIntent.FLAG_MUTABLE else 0)
                    // явный адрес — неэкспортируемый приёмник из манифеста: чужие приложения туда не достучатся
                    val cb = PendingIntent.getBroadcast(ctx, id, Intent(ctx, InstallStatusReceiver::class.java), flags)
                    s.commit(cb.intentSender)
                }
                "started"
            } catch (e: Throwable) {
                "error:" + (e.message ?: e.javaClass.simpleName)
            }
            main.post { done(r) }
        }, "self-update").start()
    }
}

/** Приёмник ответа установщика (exported=false в манифесте). */
class InstallStatusReceiver : android.content.BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) = SelfUpdate.onStatus(context, intent)
}
