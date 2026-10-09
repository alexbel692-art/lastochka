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
PERMS = ['INTERNET', 'RECORD_AUDIO', 'CAMERA', 'POST_NOTIFICATIONS', 'MODIFY_AUDIO_SETTINGS', 'ACCESS_NETWORK_STATE', 'WAKE_LOCK']
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

# --- iOS: название и описания доступа ---
plist = 'ios/Runner/Info.plist'
if os.path.exists(plist):
    KEYS = {
        'NSCameraUsageDescription': 'Камера нужна для видеозвонков и фото',
        'NSMicrophoneUsageDescription': 'Микрофон нужен для звонков и голосовых сообщений',
        'NSPhotoLibraryUsageDescription': 'Доступ к фото нужен, чтобы отправлять снимки в чат',
    }
    def plist_fn(s):
        s = re.sub(r'(<key>CFBundleDisplayName</key>\s*<string>)[^<]*', r'\1Ласточка', s)
        add = ''.join(f'\t<key>{k}</key>\n\t<string>{v}</string>\n' for k, v in KEYS.items() if f'<key>{k}</key>' not in s)
        i = s.rindex('</dict>')
        return s[:i] + add + s[i:]
    edit(plist, plist_fn)
