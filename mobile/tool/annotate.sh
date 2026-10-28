#!/usr/bin/env bash
# Запускает команду; при ошибке выводит важные строки лога как аннотацию GitHub (их видно без скачивания логов).
# Использование: tool/annotate.sh "заголовок" команда аргументы...
title="$1"; shift
log=$(mktemp)
"$@" 2>&1 | tee "$log"
code=${PIPESTATUS[0]}
if [ "$code" != "0" ] || grep -qE '^\s*error •' "$log"; then
  msg=$( (grep -E '❌' "$log" | head -10; grep -A6 'What went wrong' "$log"; grep -B2 -A12 -E '\[E\]$|Expected:|не дождались|TestFailure|Failed to load|Invalid argument' "$log" | grep -vE '^#[0-9]+ ' | head -80; grep -E 'error •|Error:|error:|^e: |ERROR:' "$log" | grep -v '^\s*info •' | head -30) | head -120)
  [ -z "$msg" ] && msg=$(tail -40 "$log")
  msg="${msg//'%'/'%25'}"; msg="${msg//$'\r'/}"; msg="${msg//$'\n'/'%0A'}"
  echo "::error title=$title::$msg"
  [ "$code" = "0" ] && code=1
fi
exit $code
