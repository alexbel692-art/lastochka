"""Готовит ios/ к сборке для App Store. Запускается в CI после `flutter create` и `tool/ci_prepare.py`.

Отличия версии для App Store (правила Apple):
• только iPhone — iPad потребовал бы отдельных скриншотов и поддержки всех поворотов экрана;
• звонок не обрывается, когда Ласточку свернули (фоновый режим audio — только пока идёт звонок);
• декларация шифрования: только стандартные открытые алгоритмы (Olm/Megolm, AES, TLS) — освобождение
  mass market, App Store Connect не спрашивает про экспорт при каждой сборке (см. docs/appstore/README.md);
• манифест конфиденциальности PrivacyInfo.xcprivacy: без слежки, данные разработчику не уходят;
• уведомления через Apple (APNs), когда Ласточка закрыта: AppDelegate отдаёт ключ устройства
  (tool/ios/appstore/AppDelegate.swift), право aps-environment — в Runner.entitlements.
  Шлюз — тот же Sygnal, что для Google Play (server/setup-push-server.sh, app id app.lastochka.ios).
"""
import os, re, shutil

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
os.chdir(ROOT)
PLIST = 'ios/Runner/Info.plist'
PBX = 'ios/Runner.xcodeproj/project.pbxproj'


def edit(path, fn):
    s = open(path, encoding='utf-8').read()
    open(path, 'w', encoding='utf-8').write(fn(s))


# --- Info.plist ---
ADD = '''\t<key>ITSAppUsesNonExemptEncryption</key>
\t<false/>
\t<key>UIBackgroundModes</key>
\t<array>
\t\t<string>audio</string>
\t</array>
'''
def plist_fn(s):
    if 'ITSAppUsesNonExemptEncryption' in s:
        return s  # уже подготовлено (повторный запуск)
    # iPad не поддерживаем — повороты для iPad не нужны
    s = re.sub(r'\s*<key>UISupportedInterfaceOrientations~ipad</key>\s*<array>.*?</array>', '', s, flags=re.S)
    i = s.rindex('</dict>')
    return s[:i] + ADD + s[i:]
edit(PLIST, plist_fn)

# --- манифест конфиденциальности (обязателен для App Store с 2024 года) ---
# Причины для «API с обязательным объяснением»: настройки приложения (shared_preferences → UserDefaults)
# и даты файлов внутри своей папки (кэш, вложения). Ничего не собирается и не отслеживается.
PRIVACY = '''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>NSPrivacyTracking</key>
	<false/>
	<key>NSPrivacyTrackingDomains</key>
	<array/>
	<key>NSPrivacyCollectedDataTypes</key>
	<array/>
	<key>NSPrivacyAccessedAPITypes</key>
	<array>
		<dict>
			<key>NSPrivacyAccessedAPIType</key>
			<string>NSPrivacyAccessedAPICategoryUserDefaults</string>
			<key>NSPrivacyAccessedAPITypeReasons</key>
			<array>
				<string>CA92.1</string>
			</array>
		</dict>
		<dict>
			<key>NSPrivacyAccessedAPIType</key>
			<string>NSPrivacyAccessedAPICategoryFileTimestamp</string>
			<key>NSPrivacyAccessedAPITypeReasons</key>
			<array>
				<string>C617.1</string>
			</array>
		</dict>
	</array>
</dict>
</plist>
'''
open('ios/Runner/PrivacyInfo.xcprivacy', 'w', encoding='utf-8').write(PRIVACY)

# файл нужно добавить в проект Xcode (группа Runner + ресурсы приложения), иначе он не попадёт в сборку
FILE_REF = 'A1A5700C2E00000000000001'
BUILD_FILE = 'A1A5700C2E00000000000002'
def pbx_fn(s):
    if 'PrivacyInfo.xcprivacy' in s:
        return s
    s = s.replace('/* Begin PBXBuildFile section */\n',
                  '/* Begin PBXBuildFile section */\n'
                  f'\t\t{BUILD_FILE} /* PrivacyInfo.xcprivacy in Resources */ = {{isa = PBXBuildFile; fileRef = {FILE_REF} /* PrivacyInfo.xcprivacy */; }};\n', 1)
    s = s.replace('/* Begin PBXFileReference section */\n',
                  '/* Begin PBXFileReference section */\n'
                  f'\t\t{FILE_REF} /* PrivacyInfo.xcprivacy */ = {{isa = PBXFileReference; lastKnownFileType = text.xml; path = PrivacyInfo.xcprivacy; sourceTree = "<group>"; }};\n', 1)
    # группа Runner: рядом с Info.plist; ресурсы: рядом с LaunchScreen.storyboard
    s, n1 = re.subn(r'(\n(\t+)97C147021CF9000F007C117D /\* Info\.plist \*/,\n)',
                    lambda m: m.group(1) + f'{m.group(2)}{FILE_REF} /* PrivacyInfo.xcprivacy */,\n', s, count=1)
    s, n2 = re.subn(r'(\n(\t+)97C147011CF9000F007C117D /\* LaunchScreen\.storyboard in Resources \*/,\n)',
                    lambda m: m.group(1) + f'{m.group(2)}{BUILD_FILE} /* PrivacyInfo.xcprivacy in Resources */,\n', s, count=1)
    if not (n1 and n2 and s.count(FILE_REF) == 3 and s.count(BUILD_FILE) == 2):
        raise SystemExit('project.pbxproj: не удалось добавить PrivacyInfo.xcprivacy — шаблон Flutter поменялся?')
    # права приложения (уведомления Apple) — во всех трёх конфигурациях Runner (Debug, Release, Profile)
    s, n4 = re.subn(r'(\n(\t+)INFOPLIST_FILE = Runner/Info\.plist;\n)',
                    lambda m: m.group(1) + f'{m.group(2)}CODE_SIGN_ENTITLEMENTS = Runner/Runner.entitlements;\n', s)
    if n4 != 3:
        raise SystemExit(f'project.pbxproj: INFOPLIST_FILE найден {n4} раз вместо 3 — шаблон Flutter поменялся?')
    # только iPhone
    s, n3 = re.subn(r'TARGETED_DEVICE_FAMILY = "1,2";', 'TARGETED_DEVICE_FAMILY = 1;', s)
    if not n3:
        raise SystemExit('project.pbxproj: не найден TARGETED_DEVICE_FAMILY')
    return s
edit(PBX, pbx_fn)

# --- уведомления Apple ---
# AppDelegate заменяем целиком: он должен совпадать с шаблоном Flutter, на который рассчитан наш файл
AD = 'ios/Runner/AppDelegate.swift'
ours = open('tool/ios/appstore/AppDelegate.swift', encoding='utf-8').read()
cur = open(AD, encoding='utf-8').read()
if cur != ours:
    if 'didInitializeImplicitFlutterEngine' not in cur or 'GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)' not in cur:
        raise SystemExit(f'{AD}: шаблон Flutter поменялся — сверьте tool/ios/appstore/AppDelegate.swift с новым шаблоном')
    shutil.copy('tool/ios/appstore/AppDelegate.swift', AD)
# development — для сборки; при выгрузке в App Store Xcode сам ставит production
open('ios/Runner/Runner.entitlements', 'w', encoding='utf-8').write('''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>aps-environment</key>
	<string>development</string>
</dict>
</plist>
''')

print('App Store: ios/ подготовлен (только iPhone, звонки в фоне, уведомления Apple, PrivacyInfo.xcprivacy)')
