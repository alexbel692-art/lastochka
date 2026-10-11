#!/usr/bin/env bash
# Проверка на эмуляторе Android 7: APK ставится, Ласточка запускается, не падает за 45 с
# и показывает экран входа. Снимок экрана и журнал — в артефакте android7-check.
set -u
PKG=app.lastochka.lastochka
mkdir -p smoke
APK=$(ls dist/*-Android.apk 2>/dev/null | head -1)
[ -n "$APK" ] || { echo "::error title=Android 7::нет общего APK для проверки"; exit 1; }
adb wait-for-device
echo "Android $(adb shell getprop ro.build.version.release | tr -d '\r'), $(basename "$APK")"
if ! adb install -r -g "$APK" > smoke/install.txt 2>&1; then
  cat smoke/install.txt
  echo "::error title=Android 7::APK не установился: $(tail -1 smoke/install.txt)"
  exit 1
fi
adb logcat -c
adb shell monkey -p "$PKG" -c android.intent.category.LAUNCHER 1 > /dev/null 2>&1
sleep 45
adb exec-out screencap -p > smoke/screen.png
adb logcat -d > smoke/logcat.txt
adb shell uiautomator dump /sdcard/ui.xml > /dev/null 2>&1 && adb pull /sdcard/ui.xml smoke/ui.xml > /dev/null 2>&1
fail=0
pid=$(adb shell pidof "$PKG" | tr -d '\r')
if [ -z "$pid" ]; then
  echo "::error title=Android 7::Ласточка закрылась в первые 45 секунд после запуска"
  fail=1
fi
if grep -q "FATAL EXCEPTION" smoke/logcat.txt; then
  echo "::error title=Android 7::падение: $(grep -A3 'FATAL EXCEPTION' smoke/logcat.txt | tr '\n' ' ' | cut -c1-400)"
  fail=1
fi
if grep -q "ANR in $PKG" smoke/logcat.txt; then
  echo "::error title=Android 7::приложение не отвечает (ANR)"
  fail=1
fi
errs=$(grep -E "E/flutter|\[ERROR:flutter" smoke/logcat.txt | head -10)
[ -n "$errs" ] && echo "::warning title=Android 7::ошибки Flutter: $(echo "$errs" | tr '\n' ' ' | cut -c1-600)"
if grep -q "Имя сервера" smoke/ui.xml 2>/dev/null; then
  echo "::notice title=Android 7::установка, запуск и экран входа — в порядке"
else
  echo "::warning title=Android 7::экран входа не найден в дереве элементов — посмотрите снимок screen.png"
fi
exit $fail
