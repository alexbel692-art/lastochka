package app.lastochka.lastochka

import android.content.Context
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    // окно подключается к уже работающей Ласточке, а при закрытии окна она продолжает работать
    override fun provideFlutterEngine(context: Context): FlutterEngine = MainApplication.engine(application)
    override fun shouldDestroyEngineWithHost(): Boolean = false
}
