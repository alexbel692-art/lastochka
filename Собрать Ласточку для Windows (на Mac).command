#!/bin/bash
# Двойной щелчок в Finder: соберёт Ласточку для Windows (.exe) прямо на Mac.
cd "$(dirname "$0")" || exit 1
if ! command -v node >/dev/null 2>&1; then
  echo "Не найден Node.js. Установите его: https://nodejs.org (LTS), затем запустите снова."
  read -n 1 -s -r -p "Нажмите любую клавишу…"; exit 1
fi
fail(){ echo; echo "❌ $1. Пришлите текст выше."; read -n 1 -s -r -p "Нажмите любую клавишу…"; exit 1; }
# Electron и инструменты сборки скачиваются с официальных серверов (GitHub).
# Если GitHub недоступен — повторяем через зеркало npmmirror. Подмену это не пропустит:
# Electron сверяется с контрольными суммами из пакета electron в реестре npm.
build(){
  echo "▶ Устанавливаю зависимости…" && npm install &&
  echo "▶ Обновляю Electron и библиотеки до версий с последними исправлениями безопасности…" && npm run harden &&
  echo "▶ Собираю…" && npm run dist:win
}
if ! build; then
  echo; echo "⚠️ С официальных серверов скачать не получилось — пробую через зеркало npmmirror…"
  export ELECTRON_MIRROR="https://npmmirror.com/mirrors/electron/"
  export ELECTRON_BUILDER_BINARIES_MIRROR="https://npmmirror.com/mirrors/electron-builder-binaries/"
  build || fail "Ошибка сборки"
fi
echo "✅ Готово. Файлы Lastochka-Setup-*.exe и Lastochka-*-portable.exe — в папке release/"
open release
