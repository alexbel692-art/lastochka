#!/usr/bin/env bash
# Запускает команду; при ошибке выводит важные строки лога как аннотацию GitHub (их видно без скачивания логов).
# Использование: tool/annotate.sh "заголовок" команда аргументы...
title="$1"; shift
log=$(mktemp)
"$@" 2>&1 | tee "$log"
code=${PIPESTATUS[0]}
if [ "$code" != "0" ] || grep -qE '^\s*error •' "$log"; then
  msg=$(grep -E 'error •|Error:|error:|FAILURE|What went wrong|Exception|^e: |\.dart:[0-9]+:[0-9]+' "$log" | grep -v '^\s*info •' | head -60)
  [ -z "$msg" ] && msg=$(tail -40 "$log")
  msg="${msg//'%'/'%25'}"; msg="${msg//$'\r'/}"; msg="${msg//$'\n'/'%0A'}"
  echo "::error title=$title::$msg"
  [ "$code" = "0" ] && code=1
fi
exit $code
