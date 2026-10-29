#!/usr/bin/env bash
# Внутри эмулятора Android: автотест интерфейса (e2e/app_test.dart) против Synapse на хосте (10.0.2.2:8008),
# затем проверка на сервере, что сообщение Ласточки действительно дошло.
set -u
cd src/mobile
mkdir -p ../../e2e-out
adb wait-for-device
adb logcat -c
code=0
flutter test integration_test/app_test.dart -d emulator-5554 \
  --dart-define=E2E_SERVER=http://10.0.2.2:8008 --dart-define=E2E_USER=alice --dart-define=E2E_PASS="$E2E_PASS" \
  --dart-define=APP_VERSION=0.0.0-e2e 2>&1 | tee ../../e2e-out/test.txt
code=${PIPESTATUS[0]}
adb logcat -d > ../../e2e-out/logcat.txt
adb exec-out screencap -p > ../../e2e-out/screen.png || true
if [ "$code" != "0" ]; then
  msg=$(grep -E "не дождались|TestFailure|Expected|E2E:|══╡" ../../e2e-out/test.txt | tail -15 | tr '\n' ' ' | cut -c1-1500)
  echo "::error title=Автотест интерфейса::$msg"
  exit 1
fi
# сервер: сообщение от alice в группе
body=$(curl -sf -H "Authorization: Bearer $E2E_BOB" "http://localhost:8008/_matrix/client/v3/rooms/$E2E_ROOM/messages?dir=b&limit=30")
if echo "$body" | jq -e '.chunk[] | select(.sender=="@alice:lastochka.test" and .content.body=="Сообщение из автотеста")' > /dev/null; then
  echo "::notice title=Автотест интерфейса::вход, фраза, группа, отправка (дошло до сервера), эмодзи, напоминание, стикеры, оформление — в порядке"
else
  echo "::error title=Автотест интерфейса::в интерфейсе отправлено, но на сервере сообщения от alice нет"
  exit 1
fi
