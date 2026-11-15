"""Готовит android/ к сборке для Google Play (AAB). Запускается в CI после сборки APK.

Отличия версии из Play (правила магазина):
• нет самообновления и разрешения ставить приложения — обновляет сам Google Play;
• нет постоянной фоновой службы и просьбы отключить экономию батареи — сообщения будит Google (FCM);
  служба с микрофоном работает только во время звонка;
• нет полного доступа к галерее — фото и видео выбираются системным окном Android.

Если задан секрет GOOGLE_SERVICES_JSON (файл google-services.json из Firebase) — подключаются
уведомления через Google: настройки Firebase, библиотека firebase-messaging и служба PushService.
"""
import json, os, re, shutil

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
os.chdir(ROOT)
PKG = 'app.lastochka.lastochka'
MAN = 'android/app/src/main/AndroidManifest.xml'
REMOVE = ['REQUEST_INSTALL_PACKAGES', 'FOREGROUND_SERVICE_REMOTE_MESSAGING', 'REQUEST_IGNORE_BATTERY_OPTIMIZATIONS',
          'READ_MEDIA_IMAGES', 'READ_MEDIA_VIDEO', 'READ_MEDIA_VISUAL_USER_SELECTED']

s = open(MAN, encoding='utf-8').read()
if 'xmlns:tools=' not in s:
    s = s.replace('<manifest ', '<manifest xmlns:tools="http://schemas.android.com/tools" ', 1)
for p in REMOVE:
    s = re.sub(r'\s*<uses-permission android:name="android\.permission\.%s"\s*/>' % p, '', s)
    # и из манифестов библиотек — тоже
    s = s.replace('<application', '<uses-permission android:name="android.permission.%s" tools:node="remove"/>\n    <application' % p, 1)
s = s.replace('android:foregroundServiceType="remoteMessaging|microphone"', 'android:foregroundServiceType="microphone"')
if 'foregroundServiceType="microphone"' not in s:
    raise SystemExit('не найдена служба SyncService в манифесте')

# признак «версия для Google Play» для Kotlin-части (SyncService.isPlay) — в манифесте: ресурс
# с таким признаком удалял сжиматель ресурсов, и Play-версия падала при запуске фоновой службы
s = s.replace('</application>', '        <meta-data android:name="lastochka_play" android:value="true"/>\n    </application>', 1)
values = 'android/app/src/main/res/values'
os.makedirs(values, exist_ok=True)

gs = os.environ.get('GOOGLE_SERVICES_JSON', '').strip()
if gs:
    j = json.loads(gs)
    client = next(c for c in j['client'] if c['client_info']['android_client_info']['package_name'] == PKG)
    pi = j['project_info']
    strings = {
        'google_app_id': client['client_info']['mobilesdk_app_id'],
        'gcm_defaultSenderId': pi['project_number'],
        'google_api_key': client['api_key'][0]['current_key'],
        'google_crash_reporting_api_key': client['api_key'][0]['current_key'],
        'project_id': pi['project_id'],
    }
    if pi.get('storage_bucket'):
        strings['google_storage_bucket'] = pi['storage_bucket']
    body = ''.join(f'    <string name="{k}" translatable="false">{v}</string>\n' for k, v in strings.items())
    open(f'{values}/firebase.xml', 'w', encoding='utf-8').write(f'<?xml version="1.0" encoding="utf-8"?>\n<resources>\n{body}</resources>\n')
    shutil.copy('tool/android/play/PushService.kt', f'android/app/src/main/kotlin/{PKG.replace(".", "/")}/PushService.kt')
    svc = '''        <service android:name=".PushService" android:exported="false">
            <intent-filter>
                <action android:name="com.google.firebase.MESSAGING_EVENT"/>
            </intent-filter>
        </service>
        <!-- Ласточка не отправляет Google статистику -->
        <meta-data android:name="firebase_analytics_collection_deactivated" android:value="true"/>
        <meta-data android:name="google_analytics_adid_collection_enabled" android:value="false"/>
'''
    s = s.replace('</application>', svc + '    </application>', 1)
    g = 'android/app/build.gradle.kts'
    open(g, 'a', encoding='utf-8').write('\ndependencies {\n    implementation("com.google.firebase:firebase-messaging:24.1.0")\n}\n')
    print('Google Play: уведомления через Google (FCM) включены, проект', pi['project_id'])
else:
    print('::warning::нет секрета GOOGLE_SERVICES_JSON — версия для Google Play без уведомлений в фоне')

open(MAN, 'w', encoding='utf-8').write(s)
print('Google Play: манифест подготовлен')
