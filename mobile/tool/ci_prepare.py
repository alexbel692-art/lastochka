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
PERMS = ['INTERNET', 'RECORD_AUDIO', 'CAMERA', 'POST_NOTIFICATIONS', 'MODIFY_AUDIO_SETTINGS', 'ACCESS_NETWORK_STATE', 'CHANGE_NETWORK_STATE', 'WAKE_LOCK', 'BLUETOOTH_CONNECT']
def manifest(s):
    for p in PERMS:
        line = f'<uses-permission android:name="android.permission.{p}"/>'
        if line not in s:
            s = s.replace('<application', line + '\n    <application', 1)
    s = re.sub(r'android:label="[^"]*"', 'android:label="Ласточка"', s)
    return s
edit('android/app/src/main/AndroidManifest.xml', manifest)

gradle = 'android/app/build.gradle.kts'
signed = os.path.exists('android/key.properties')
def gradle_fn(s):
    s = s.replace('minSdk = flutter.minSdkVersion', 'minSdk = 23')
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
