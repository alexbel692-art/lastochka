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
PERMS = ['FOREGROUND_SERVICE', 'FOREGROUND_SERVICE_REMOTE_MESSAGING', 'FOREGROUND_SERVICE_MICROPHONE', 'USE_FULL_SCREEN_INTENT', 'RECEIVE_BOOT_COMPLETED', 'VIBRATE', 'REQUEST_IGNORE_BATTERY_OPTIMIZATIONS', 'REQUEST_INSTALL_PACKAGES', 'INTERNET', 'RECORD_AUDIO', 'CAMERA', 'POST_NOTIFICATIONS', 'MODIFY_AUDIO_SETTINGS', 'ACCESS_NETWORK_STATE', 'CHANGE_NETWORK_STATE', 'WAKE_LOCK', 'BLUETOOTH_CONNECT', 'READ_MEDIA_IMAGES', 'READ_MEDIA_VIDEO', 'READ_MEDIA_VISUAL_USER_SELECTED', 'READ_EXTERNAL_STORAGE']
def manifest(s):
    for p in PERMS:
        line = f'<uses-permission android:name="android.permission.{p}"/>'
        if line not in s:
            s = s.replace('<application', line + '\n    <application', 1)
    s = re.sub(r'android:label="[^"]*"', 'android:label="Ласточка"', s)
    # приложение и окно: движок живёт после закрытия окна, звонок показывается поверх блокировки
    # данные Ласточки не попадают в резервные копии Android (облако, adb backup)
    if 'android:allowBackup' not in s:
        s = s.replace('<application', '<application\n        android:allowBackup="false"\n        android:fullBackupContent="false"\n        android:dataExtractionRules="@xml/data_extraction_rules"', 1)
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
        <receiver android:exported="false" android:name=".InstallStatusReceiver"/>
        <receiver android:exported="false" android:name=".CallActionReceiver"/>
        <activity android:name=".CallLockActivity" android:exported="false"
            android:showWhenLocked="true" android:turnScreenOn="true"
            android:excludeFromRecents="true" android:taskAffinity="app.lastochka.call"
            android:launchMode="singleTop" android:theme="@android:style/Theme.Material.NoActionBar"/>
'''
    if '.SyncService' not in s:
        s = s.replace('</application>', comps + '    </application>', 1)
    # окно Ласточки — всегда одно: уведомление о звонке, нажатие на сообщение, обновление открывают
    # уже существующее окно (onNewIntent), а не второе. Два окна на один движок Flutter роняли
    # приложение после звонка («FlutterEngine … attached to by another activity»)
    s, n = re.subn(r'android:launchMode="[^"]*"', 'android:launchMode="singleTask"', s, count=1)
    if n == 0:
        s = s.replace('android:name=".MainActivity"', 'android:name=".MainActivity"\n            android:launchMode="singleTask"', 1)
    if 'android:launchMode="singleTask"' not in s:
        raise SystemExit('не удалось задать launchMode="singleTask" для окна Ласточки')
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
# в CI APK подписывается отдельным этапом (android-sign); здесь — только если ключ положили для локальной сборки
signed = os.path.exists('android/key.properties')
def gradle_fn(s):
    s = s.replace('minSdk = flutter.minSdkVersion', 'minSdk = 23')
    # уведомлениям нужна поддержка новых функций Java на старых Android
    if 'isCoreLibraryDesugaringEnabled' not in s:
        s = s.replace('compileOptions {', 'compileOptions {\n        isCoreLibraryDesugaringEnabled = true', 1)
        s += '\ndependencies {\n    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")\n    implementation("androidx.appcompat:appcompat:1.7.0")\n    // та же версия Media3, что у модуля video_player — иначе части библиотеки не сойдутся\n    implementation("androidx.media3:media3-transformer:1.9.2")\n    implementation("androidx.media3:media3-effect:1.9.2")\n    implementation("androidx.media3:media3-common:1.9.2")\n}\n'
    s = re.sub(r'ndkVersion = .*', 'ndkVersion = "27.0.12077973"', s)
    # сборка под один тип процессора (--target-platform) — и библиотеки плагинов (звонки, сканер QR)
    # кладём только для него, иначе в APK попадают все три набора
    if 'abiFilters' not in s:
        assert '    defaultConfig {' in s, 'defaultConfig не найден'
        s = s.replace('    defaultConfig {', """    defaultConfig {
        val abi = System.getenv("LASTOCHKA_ABI")
        if (!abi.isNullOrEmpty()) ndk { abiFilters.clear(); abiFilters.add(abi) }""", 1)
        # Flutter сам добавляет все типы процессоров — лишние библиотеки вырезаем при упаковке
        s = s.replace('\nandroid {', """
android {
    System.getenv("LASTOCHKA_ABI")?.takeIf { it.isNotEmpty() }?.let { keep ->
        packaging { jniLibs { excludes += listOf("arm64-v8a", "armeabi-v7a", "x86_64", "x86").filter { it != keep }.map { "lib/$it/**" } } }
    }""", 1)
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
        # шаблон Flutter поменялся и подстановка не сработала — лучше остановить сборку, чем выпустить APK с временной подписью
        assert 'signingConfigs.getByName("release")' in s, 'ci_prepare: подпись release не подставлена в build.gradle.kts'
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
    'NSPhotoLibraryAddUsageDescription': 'Ласточка сохраняет фото и видео из чатов в вашу галерею',
    'NSFaceIDUsageDescription': 'Face ID нужен, чтобы разблокировать Ласточку без код-пароля',
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
# macOS: все файлы, которые создаёт Ласточка (вложения из чатов), получают карантин Gatekeeper
if os.path.exists('macos/Runner/Info.plist'):
    def quarantine_fn(s):
        if 'LSFileQuarantineEnabled' in s:
            return s
        i = s.rindex('</dict>')
        return s[:i] + '\t<key>LSFileQuarantineEnabled</key>\n\t<true/>\n' + s[i:]
    edit('macos/Runner/Info.plist', quarantine_fn)

# --- macOS: разрешения песочницы (сеть, камера, микрофон, выбор файлов) ---
ENT = ['com.apple.security.network.client', 'com.apple.security.network.server', 'com.apple.security.device.camera',
       'com.apple.security.device.audio-input', 'com.apple.security.files.user-selected.read-write', 'com.apple.security.files.downloads.read-write']
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
    # модуль Windows Hello (local_auth) использует старые заголовки сопрограмм — новый компилятор их отвергает
    edit('windows/CMakeLists.txt', lambda s: s if '_SILENCE_EXPERIMENTAL_COROUTINE' in s else re.sub(r'(project\([^)]*\)\n)', r'\1add_compile_definitions(_SILENCE_EXPERIMENTAL_COROUTINE_DEPRECATION_WARNINGS)\n', s, count=1))
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
  // перезапуск после переподключения к RDP: ждём, пока прежняя копия завершится (до 10 с)
  if (wcsstr(GetCommandLineW(), L"--restart") != nullptr) {{
    for (int i = 0; i < 50 && single != nullptr && GetLastError() == ERROR_ALREADY_EXISTS; i++) {{
      CloseHandle(single);
      Sleep(200);
      single = CreateMutexW(nullptr, TRUE, L"LastochkaSingleInstance");
    }}
  }}
  if (single != nullptr && GetLastError() == ERROR_ALREADY_EXISTS) {{
    HWND w = FindWindowW(L"FLUTTER_RUNNER_WIN32_WINDOW", {title});
    if (w) {{ ShowWindow(w, SW_SHOW); ShowWindow(w, SW_RESTORE); SetForegroundWindow(w); }}
    return EXIT_SUCCESS;
  }}
"""
        return s[:m.end()] + code + s[m.end():]
    edit(mc, mc_fn)

# --- Windows: запись падений на уровне системы. Ошибку внутри видеомодуля, mpv или графики Ласточка сама не видит —
# процесс просто закрывается. Обработчик пишет в %TEMP%\lastochka_native_crash.txt код ошибки и модуль, в котором
# она случилась; при следующем запуске это попадает в отчёт («Настройки → отправить отчёт»).
if os.path.exists(mc):
    def crash_fn(s):
        if 'LastochkaCrash' in s:
            return s
        inc = '#include "utils.h"\n'
        if inc not in s:
            raise SystemExit('main.cpp: шаблон изменился, запись падений не добавлена')
        s = s.replace(inc, inc + r'''
#include <cstdio>
#include <cwchar>

// Unhandled native crash -> one line in %TEMP%\lastochka_native_crash.txt (code, module, offset).
static LONG WINAPI LastochkaCrash(EXCEPTION_POINTERS* ep) {
  wchar_t path[MAX_PATH];
  const DWORD n = GetTempPathW(MAX_PATH, path);
  if (n == 0 || n > MAX_PATH - 40) return EXCEPTION_CONTINUE_SEARCH;
  wcscat_s(path, MAX_PATH, L"lastochka_native_crash.txt");
  FILE* f = nullptr;
  if (_wfopen_s(&f, path, L"a") != 0 || f == nullptr) return EXCEPTION_CONTINUE_SEARCH;
  void* addr = ep->ExceptionRecord->ExceptionAddress;
  HMODULE mod = nullptr;
  wchar_t name[MAX_PATH] = L"?";
  if (GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                         static_cast<LPCWSTR>(addr), &mod) && mod != nullptr) {
    GetModuleFileNameW(mod, name, MAX_PATH);
  }
  const wchar_t* base = wcsrchr(name, L'\\');
  base = base ? base + 1 : name;
  SYSTEMTIME t;
  GetLocalTime(&t);
  fwprintf(f, L"%04u-%02u-%02u %02u:%02u:%02u code=0x%08lX module=%ls offset=0x%llX\n",
           t.wYear, t.wMonth, t.wDay, t.wHour, t.wMinute, t.wSecond,
           static_cast<unsigned long>(ep->ExceptionRecord->ExceptionCode), base,
           static_cast<unsigned long long>(reinterpret_cast<const char*>(addr) - reinterpret_cast<const char*>(mod)));
  fclose(f);
  return EXCEPTION_CONTINUE_SEARCH;
}
''', 1)
        m = re.search(r'(wWinMain\([^)]*\)\s*\{)', s)
        return s[:m.end()] + '\n  SetUnhandledExceptionFilter(LastochkaCrash);' + s[m.end():]
    edit(mc, crash_fn)

# --- Windows: при автозапуске (--hidden) окно не показывается — Ласточка стартует в трее ---
fw = 'windows/runner/flutter_window.cpp'
if os.path.exists(fw):
    edit(fw, lambda s: s.replace('this->Show();', 'if (wcsstr(GetCommandLineW(), L"--hidden") == nullptr) this->Show();') if '--hidden' not in s else s)

# --- Windows: переподключение к RDP-сеансу. При отключении сеанса Windows сбрасывает графику окна, и Flutter
# её не восстанавливает — после переподключения окно белое и не отвечает. Ласточка ловит переподключение
# и через 1,5 с тихо перезапускается в том же виде (окно или трей); вход и переписка сохраняются.
if os.path.exists(fw):
    def rdp_fn(s):
        if 'WM_WTSSESSION_CHANGE' in s:
            return s
        head = '#include "flutter_window.h"\n'
        if head not in s or 'SetChildContent(' not in s or '  switch (message) {\n' not in s:
            raise SystemExit('flutter_window.cpp: шаблон изменился, обработчик переподключения RDP не добавлен')
        s = s.replace(head, head + '''
#include <wtsapi32.h>
#include <string>
#pragma comment(lib, "Wtsapi32.lib")

namespace {
constexpr UINT_PTR kLastochkaReconnectTimer = 0x4C41;

// Restart Lastochka in the same state: visible window -> window, hidden in tray -> tray (ASCII only: MSVC /WX).
void LastochkaRestart(HWND hwnd) {
  wchar_t path[MAX_PATH];
  if (GetModuleFileNameW(nullptr, path, MAX_PATH) == 0) return;
  const bool visible = IsWindowVisible(hwnd) != FALSE;
  std::wstring cmd = L"\\"" + std::wstring(path) + L"\\" --restart" + (visible ? L"" : L" --hidden");
  STARTUPINFOW si{};
  si.cb = sizeof(si);
  PROCESS_INFORMATION pi{};
  if (CreateProcessW(nullptr, cmd.data(), nullptr, nullptr, FALSE, 0, nullptr, nullptr, &si, &pi)) {
    CloseHandle(pi.hThread);
    CloseHandle(pi.hProcess);
    ExitProcess(0);
  }
}
}  // namespace
''', 1)
        i = s.index('SetChildContent(')
        j = s.index(';', i) + 1
        s = s[:j] + '\n  WTSRegisterSessionNotification(GetHandle(), NOTIFY_FOR_THIS_SESSION);' + s[j:]
        s = s.replace('  switch (message) {\n', '''  switch (message) {
    case WM_WTSSESSION_CHANGE:
      if (wparam == WTS_REMOTE_CONNECT || wparam == WTS_CONSOLE_CONNECT) {
        SetTimer(hwnd, kLastochkaReconnectTimer, 1500, nullptr);
      }
      break;
    case WM_TIMER:
      if (wparam == kLastochkaReconnectTimer) {
        KillTimer(hwnd, kLastochkaReconnectTimer);
        LastochkaRestart(hwnd);
        return 0;
      }
      break;
''', 1)
        return s
    edit(fw, rdp_fn)

# --- Android: тема AppCompat (нужна окну входа по отпечатку на Android 8 и старше) ---
for st in ('android/app/src/main/res/values/styles.xml', 'android/app/src/main/res/values-night/styles.xml'):
    if os.path.exists(st):
        def st_fn(s):
            s = s.replace('@android:style/Theme.Light.NoTitleBar', 'Theme.AppCompat.Light.NoActionBar')
            s = s.replace('@android:style/Theme.Black.NoTitleBar', 'Theme.AppCompat.NoActionBar')
            return s
        edit(st, st_fn)

# --- Android: экран запуска в цветах Ласточки (дальше его продолжает анимация в самом приложении) ---
launch = """<?xml version="1.0" encoding="utf-8"?>
<layer-list xmlns:android="http://schemas.android.com/apk/res/android">
    <item android:drawable="@color/lastochka_splash" />
    <item android:gravity="center" android:drawable="@mipmap/ic_launcher" />
</layer-list>
"""
for d in ('drawable', 'drawable-v21'):
    f = f'android/app/src/main/res/{d}/launch_background.xml'
    if os.path.isdir(os.path.dirname(f)):
        open(f, 'w', encoding='utf-8').write(launch)
os.makedirs('android/app/src/main/res/values', exist_ok=True)
open('android/app/src/main/res/values/lastochka_colors.xml', 'w', encoding='utf-8').write(
    '<?xml version="1.0" encoding="utf-8"?>\n<resources>\n    <color name="lastochka_splash">#2F7FE8</color>\n</resources>\n')
# Android 12+: системный экран запуска — тот же цвет
v31 = """<?xml version="1.0" encoding="utf-8"?>
<resources>
    <style name="LaunchTheme" parent="Theme.AppCompat.Light.NoActionBar">
        <item name="android:windowBackground">@drawable/launch_background</item>
        <item name="android:windowSplashScreenBackground">@color/lastochka_splash</item>
    </style>
    <style name="NormalTheme" parent="Theme.AppCompat.Light.NoActionBar">
        <item name="android:windowBackground">?android:colorBackground</item>
    </style>
</resources>
"""
for d, theme in (('values-v31', 'Theme.AppCompat.Light.NoActionBar'), ('values-night-v31', 'Theme.AppCompat.NoActionBar')):
    os.makedirs(f'android/app/src/main/res/{d}', exist_ok=True)
    open(f'android/app/src/main/res/{d}/styles.xml', 'w', encoding='utf-8').write(v31.replace('Theme.AppCompat.Light.NoActionBar', theme))

# --- macOS: защита окна от снимков экрана (настройка «Запретить снимки экрана») ---
mw = 'macos/Runner/MainFlutterWindow.swift'
if os.path.exists(mw):
    def mw_fn(s):
        if 'lastochka/window' in s:
            return s
        anchor = 'RegisterGeneratedPlugins(registry: flutterViewController)'
        code = anchor + """
    let lastochkaWindow = FlutterMethodChannel(name: "lastochka/window", binaryMessenger: flutterViewController.engine.binaryMessenger)
    lastochkaWindow.setMethodCallHandler { [weak self] call, result in
      if call.method == "protect" {
        self?.sharingType = (call.arguments as? Bool ?? false) ? .none : .readOnly
        result(true)
      } else {
        result(FlutterMethodNotImplemented)
      }
    }"""
        return s.replace(anchor, code, 1)
    edit(mw, mw_fn)

# --- Android 12+: не переносить данные ни в облако, ни на новый телефон ---
if os.path.isdir('android/app/src/main/res'):
    os.makedirs('android/app/src/main/res/xml', exist_ok=True)
    with open('android/app/src/main/res/xml/data_extraction_rules.xml', 'w', encoding='utf-8') as f:
        f.write("""<?xml version="1.0" encoding="utf-8"?>
<data-extraction-rules>
    <cloud-backup>
        <exclude domain="root"/><exclude domain="file"/><exclude domain="database"/><exclude domain="sharedpref"/><exclude domain="external"/>
    </cloud-backup>
    <device-transfer>
        <exclude domain="root"/><exclude domain="file"/><exclude domain="database"/><exclude domain="sharedpref"/><exclude domain="external"/>
    </device-transfer>
</data-extraction-rules>
""")
