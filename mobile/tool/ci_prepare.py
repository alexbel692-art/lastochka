"""Настраивает сгенерированные папки android/ и ios/ после `flutter create` (запускается в CI)."""
import os, re, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
os.chdir(ROOT)

def edit(path, fn):
    s = open(path, encoding='utf-8').read()
    n = fn(s)
    if n != s:
        open(path, 'w', encoding='utf-8').write(n)
        print('patched', path)

# --- Android: разрешения и название ---
PERMS = ['FOREGROUND_SERVICE', 'FOREGROUND_SERVICE_REMOTE_MESSAGING', 'FOREGROUND_SERVICE_MICROPHONE', 'USE_FULL_SCREEN_INTENT', 'RECEIVE_BOOT_COMPLETED', 'VIBRATE', 'REQUEST_IGNORE_BATTERY_OPTIMIZATIONS', 'INTERNET', 'RECORD_AUDIO', 'CAMERA', 'POST_NOTIFICATIONS', 'MODIFY_AUDIO_SETTINGS', 'ACCESS_NETWORK_STATE', 'CHANGE_NETWORK_STATE', 'WAKE_LOCK', 'BLUETOOTH_CONNECT']
def manifest(s):
    for p in PERMS:
        line = f'<uses-permission android:name="android.permission.{p}"/>'
        if line not in s:
            s = s.replace('<application', line + '\n    <application', 1)
    s = re.sub(r'android:label="[^"]*"', 'android:label="Ласточка"', s)
    # приложение и окно: движок живёт после закрытия окна, звонок показывается поверх блокировки
    if 'android:name=".MainApplication"' not in s:
        if 'android:name="${applicationName}"' in s:
            s = s.replace('android:name="${applicationName}"', 'android:name=".MainApplication"', 1)
        else:
            s = s.replace('<application', '<application\n        android:name=".MainApplication"', 1)
    comps = '''
        <service android:name=".SyncService" android:exported="false" android:foregroundServiceType="remoteMessaging|microphone"/>
        <receiver android:name=".BootReceiver" android:exported="true">
            <intent-filter>
                <action android:name="android.intent.action.BOOT_COMPLETED"/>
                <action android:name="android.intent.action.MY_PACKAGE_REPLACED"/>
            </intent-filter>
        </receiver>
        <receiver android:exported="false" android:name="com.dexterous.flutterlocalnotifications.ActionBroadcastReceiver"/>
'''
    if '.SyncService' not in s:
        s = s.replace('</application>', comps + '    </application>', 1)
    return s
edit('android/app/src/main/AndroidManifest.xml', manifest)

import shutil, glob
kt_dir = 'android/app/src/main/kotlin/app/lastochka/lastochka'
if os.path.isdir('android'):
    os.makedirs(kt_dir, exist_ok=True)
    for f in glob.glob('tool/android/*.kt'):
        shutil.copy(f, kt_dir)
    os.makedirs('android/app/src/main/res/drawable', exist_ok=True)
    shutil.copy('tool/android/ic_notification.xml', 'android/app/src/main/res/drawable/ic_notification.xml')

gradle = 'android/app/build.gradle.kts'
signed = os.path.exists('android/key.properties')
def gradle_fn(s):
    s = s.replace('minSdk = flutter.minSdkVersion', 'minSdk = 23')
    # уведомлениям нужна поддержка новых функций Java на старых Android
    if 'isCoreLibraryDesugaringEnabled' not in s:
        s = s.replace('compileOptions {', 'compileOptions {\n        isCoreLibraryDesugaringEnabled = true', 1)
        s += '\ndependencies {\n    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")\n    implementation("androidx.appcompat:appcompat:1.7.0")\n}\n'
    s = re.sub(r'ndkVersion = .*', 'ndkVersion = "27.0.12077973"', s)
    if signed and 'create("release")' not in s:
        block = '''    signingConfigs {
        create("release") {
            storeFile = file(keystoreProperties["storeFile"] as String)
            storePassword = keystoreProperties["storePassword"] as String
            keyAlias = keystoreProperties["keyAlias"] as String
            keyPassword = keystoreProperties["keyPassword"] as String
        }
    }

    buildTypes {'''
        s = s.replace('    buildTypes {', block, 1)
        header = 'import java.io.FileInputStream\nimport java.util.Properties\n\n'
        props = '\nval keystoreProperties = Properties().apply { load(FileInputStream(rootProject.file("key.properties"))) }\n\nandroid {'
        s = header + s.replace('\nandroid {', props, 1)
        s = s.replace('signingConfig = signingConfigs.getByName("debug")', 'signingConfig = signingConfigs.getByName("release")')
    return s
edit(gradle, gradle_fn)
print('android signing:', 'release key' if signed else 'DEBUG key (секрет ANDROID_KEYSTORE не задан)')

# правила сжатия кода: модуль звонков WebRTC вызывается из нативного кода
with open('android/app/proguard-rules.pro', 'a', encoding='utf-8') as f:
    f.write('-keep class org.webrtc.** { *; }\n-keep class com.cloudwebrtc.webrtc.** { *; }\n')

# --- iOS и macOS: название и описания доступа ---
USAGE = {
    'NSCameraUsageDescription': 'Камера нужна для видеозвонков и фото',
    'NSMicrophoneUsageDescription': 'Микрофон нужен для звонков и голосовых сообщений',
    'NSPhotoLibraryUsageDescription': 'Доступ к фото нужен, чтобы отправлять снимки в чат',
}
def plist_fn(s):
    if '<key>CFBundleDisplayName</key>' in s:
        s = re.sub(r'(<key>CFBundleDisplayName</key>\s*<string>)[^<]*', r'\1Ласточка', s)
    else:
        USAGE['CFBundleDisplayName'] = 'Ласточка'
    add = ''.join(f'\t<key>{k}</key>\n\t<string>{v}</string>\n' for k, v in USAGE.items() if f'<key>{k}</key>' not in s)
    USAGE.pop('CFBundleDisplayName', None)
    i = s.rindex('</dict>')
    return s[:i] + add + s[i:]
for plist in ('ios/Runner/Info.plist', 'macos/Runner/Info.plist'):
    if os.path.exists(plist):
        edit(plist, plist_fn)

# --- macOS: разрешения песочницы (сеть, камера, микрофон, выбор файлов) ---
ENT = ['com.apple.security.network.client', 'com.apple.security.network.server', 'com.apple.security.device.camera',
       'com.apple.security.device.audio-input', 'com.apple.security.files.user-selected.read-only']
def ent_fn(s):
    add = ''.join(f'\t<key>{k}</key>\n\t<true/>\n' for k in ENT if f'<key>{k}</key>' not in s)
    i = s.rindex('</dict>')
    return s[:i] + add + s[i:]
for e in ('macos/Runner/DebugProfile.entitlements', 'macos/Runner/Release.entitlements'):
    if os.path.exists(e):
        edit(e, ent_fn)
if os.path.exists('macos/Runner/Configs/AppInfo.xcconfig'):
    edit('macos/Runner/Configs/AppInfo.xcconfig', lambda s: re.sub(r'PRODUCT_NAME = .*', 'PRODUCT_NAME = Lastochka', s))

# --- Windows: имя программы и заголовок окна ---
if os.path.exists('windows/CMakeLists.txt'):
    edit('windows/CMakeLists.txt', lambda s: s.replace('set(BINARY_NAME "lastochka")', 'set(BINARY_NAME "Lastochka")'))
    edit('windows/runner/main.cpp', lambda s: s.replace('L"lastochka"', 'L"\\u041b\\u0430\\u0441\\u0442\\u043e\\u0447\\u043a\\u0430"'))
    def rc(s):
        for k in ('CompanyName', 'FileDescription', 'ProductName', 'InternalName'):
            s = re.sub(r'(VALUE "%s", )"[^"]*"' % k, r'\1"Lastochka"', s)
        return re.sub(r'(VALUE "LegalCopyright", )"[^"]*"', r'\1""', s)
    edit('windows/runner/Runner.rc', rc)

# --- macOS: закрытие окна не завершает Ласточку, клик по значку в Dock снова открывает окно ---
ad = 'macos/Runner/AppDelegate.swift'
if os.path.exists(ad):
    def ad_fn(s):
        s = re.sub(r'(applicationShouldTerminateAfterLastWindowClosed\(_ sender: NSApplication\) -> Bool \{\s*return )true', r'\1false', s)
        if 'applicationShouldHandleReopen' not in s:
            i = s.rindex('}')
            s = s[:i] + """
  override func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    if !flag { for window in sender.windows { window.makeKeyAndOrderFront(self) } }
    NSApp.activate(ignoringOtherApps: true)
    return true
  }
""" + s[i:]
        return s
    edit(ad, ad_fn)

# --- Windows: одна копия Ласточки на пользователя (повторный запуск показывает окно из трея) ---
mc = 'windows/runner/main.cpp'
if os.path.exists(mc):
    def mc_fn(s):
        if 'LastochkaSingleInstance' in s:
            return s
        m = re.search(r'(wWinMain\([^)]*\)\s*\{)', s)
        title = 'L"\\u041b\\u0430\\u0441\\u0442\\u043e\\u0447\\u043a\\u0430"'
        code = f"""
  HANDLE single = CreateMutexW(nullptr, TRUE, L"LastochkaSingleInstance");
  if (single != nullptr && GetLastError() == ERROR_ALREADY_EXISTS) {{
    HWND w = FindWindowW(L"FLUTTER_RUNNER_WIN32_WINDOW", {title});
    if (w) {{ ShowWindow(w, SW_SHOW); ShowWindow(w, SW_RESTORE); SetForegroundWindow(w); }}
    return EXIT_SUCCESS;
  }}
"""
        return s[:m.end()] + code + s[m.end():]
    edit(mc, mc_fn)

# --- Windows: при автозапуске (--hidden) окно не показывается — Ласточка стартует в трее ---
fw = 'windows/runner/flutter_window.cpp'
if os.path.exists(fw):
    edit(fw, lambda s: s.replace('this->Show();', 'if (wcsstr(GetCommandLineW(), L"--hidden") == nullptr) this->Show();') if '--hidden' not in s else s)

# --- Android: тема AppCompat (нужна окну входа по отпечатку на Android 8 и старше) ---
for st in ('android/app/src/main/res/values/styles.xml', 'android/app/src/main/res/values-night/styles.xml'):
    if os.path.exists(st):
        def st_fn(s):
            s = s.replace('@android:style/Theme.Light.NoTitleBar', 'Theme.AppCompat.Light.NoActionBar')
            s = s.replace('@android:style/Theme.Black.NoTitleBar', 'Theme.AppCompat.NoActionBar')
            return s
        edit(st, st_fn)
