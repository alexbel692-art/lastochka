#!/usr/bin/env bash
# Сервер уведомлений: шлюз Ласточки (Sygnal) + место для сервера «Хвостиков».
#
# Что делает (на чистом Ubuntu 22.04 или 24.04, от root; можно запускать повторно — ничего не сломает):
#   • обновления безопасности ставятся сами, подкачка 1 ГБ, межсетевой экран (открыты только SSH, 80, 443),
#     защита SSH от подбора пароля (fail2ban);
#   • Docker;
#   • Caddy — сам получает и продлевает HTTPS-сертификаты для обоих поддоменов;
#   • Sygnal — шлюз уведомлений Matrix для Ласточки (Android через Firebase; iPhone — когда будет ключ Apple);
#   • для «Хвостиков» — адрес с HTTPS, который ведёт на их сервер (контейнер pets-api, порт 8080).
#
# Запуск:
#   PUSH_DOMAIN=push.ваш-домен PETS_DOMAIN=api.ваш-домен EMAIL=почта bash setup-push-server.sh
# (без переменных скрипт спросит сам). PETS_DOMAIN можно не указывать — тогда только шлюз.
#
# Ключи кладутся рядом с настройками шлюза, в /opt/push/sygnal/, и после этого скрипт запускается ещё раз:
#   firebase-lastochka.json — закрытый ключ сервисного аккаунта Firebase (Настройки проекта → Сервисные аккаунты)
#   apns-lastochka.p8       — ключ push-уведомлений Apple (позже) + переменные APNS_KEY_ID и APNS_TEAM_ID
# Сами ключи никуда не пересылаются и в репозиторий не попадают.
set -euo pipefail

SYGNAL_IMAGE="matrixdotorg/sygnal:v0.17.0"
CADDY_IMAGE="caddy:2"
BASE=/opt/push
ANDROID_APP_ID="app.lastochka.android"
IOS_APP_ID="app.lastochka.ios"
IOS_BUNDLE="app.lastochka.lastochka"

say() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[!] %s\033[0m\n' "$*"; }
die() { printf '\033[1;31m[x] %s\033[0m\n' "$*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || die "Запустите от root: sudo bash $0"
grep -qi ubuntu /etc/os-release || warn "Скрипт проверен на Ubuntu; на другой системе возможны отличия"

: "${PUSH_DOMAIN:=}"; : "${PETS_DOMAIN:=}"; : "${EMAIL:=}"
[ -n "$PUSH_DOMAIN" ] || read -rp "Поддомен шлюза Ласточки (например push.example.ru): " PUSH_DOMAIN
[ -n "$PETS_DOMAIN" ] || read -rp "Поддомен сервера «Хвостиков» (Enter — пропустить): " PETS_DOMAIN
[ -n "$EMAIL" ] || read -rp "Почта для писем о сертификатах HTTPS: " EMAIL
valid_host() { [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$ ]]; }
valid_host "$PUSH_DOMAIN" || die "Неверный поддомен шлюза: '$PUSH_DOMAIN'"
[ -z "$PETS_DOMAIN" ] || valid_host "$PETS_DOMAIN" || die "Неверный поддомен «Хвостиков»: '$PETS_DOMAIN'"
[[ "$EMAIL" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]] || die "Неверная почта: '$EMAIL'"

say "Пакеты и обновления безопасности"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq ca-certificates curl ufw fail2ban unattended-upgrades python3 dnsutils >/dev/null
dpkg-reconfigure -f noninteractive unattended-upgrades >/dev/null 2>&1 || true
systemctl enable --now fail2ban >/dev/null 2>&1 || true

say "Проверка DNS: поддомены должны указывать на этот сервер"
MYIP="$(curl -4 -fsS --max-time 10 https://api.ipify.org || true)"
for d in "$PUSH_DOMAIN" ${PETS_DOMAIN:+"$PETS_DOMAIN"}; do
  got="$(dig +short A "$d" | tail -1)"
  if [ -z "$got" ]; then
    warn "$d пока не найден в DNS — HTTPS-сертификат выдадут, когда запись появится"
  elif [ -n "$MYIP" ] && [ "$got" != "$MYIP" ]; then
    warn "$d указывает на $got, а у этого сервера адрес $MYIP — проверьте запись A"
  else
    echo "  $d → $got — верно"
  fi
done

say "Подкачка 1 ГБ (чтобы при нехватке памяти ничего не падало)"
if ! swapon --show | grep -q .; then
  fallocate -l 1G /swapfile && chmod 600 /swapfile && mkswap /swapfile >/dev/null && swapon /swapfile
  grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
  echo "  включена"
else
  echo "  уже есть"
fi

say "Межсетевой экран: открыты только SSH, 80 и 443"
ufw allow OpenSSH >/dev/null
ufw allow 80/tcp >/dev/null
ufw allow 443/tcp >/dev/null
ufw allow 443/udp >/dev/null
ufw --force enable >/dev/null
ufw status | sed 's/^/  /'

say "Docker"
if ! command -v docker >/dev/null; then
  curl -fsSL https://get.docker.com | sh >/dev/null
fi
systemctl enable --now docker >/dev/null
docker network inspect web >/dev/null 2>&1 || docker network create web >/dev/null
docker --version

say "Настройки шлюза Ласточки"
mkdir -p "$BASE/sygnal" "$BASE/caddy" /opt/apps/pets
chmod 700 "$BASE/sygnal"
APPS=""
FB="$BASE/sygnal/firebase-lastochka.json"
if [ -f "$FB" ]; then
  chmod 600 "$FB"
  PROJECT_ID="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["project_id"])' "$FB")" || die "Не читается $FB — это точно ключ сервисного аккаунта Firebase?"
  APPS+="
  $ANDROID_APP_ID:
    type: gcm
    api_version: v1
    project_id: $PROJECT_ID
    service_account_file: /data/firebase-lastochka.json"
  echo "  Android (Firebase, проект $PROJECT_ID) — подключён"
else
  warn "Нет $FB — Android-уведомления через Firebase пока выключены (положите ключ и запустите скрипт ещё раз)"
fi
P8="$BASE/sygnal/apns-lastochka.p8"
if [ -f "$P8" ]; then
  : "${APNS_KEY_ID:=}"; : "${APNS_TEAM_ID:=}"
  [ -n "$APNS_KEY_ID" ] || read -rp "Key ID ключа Apple (10 знаков): " APNS_KEY_ID
  [ -n "$APNS_TEAM_ID" ] || read -rp "Team ID аккаунта Apple (10 знаков): " APNS_TEAM_ID
  chmod 600 "$P8"
  APPS+="
  $IOS_APP_ID:
    type: apns
    keyfile: /data/apns-lastochka.p8
    key_id: $APNS_KEY_ID
    team_id: $APNS_TEAM_ID
    topic: $IOS_BUNDLE"
  echo "  iPhone (Apple) — подключён"
else
  echo "  iPhone — позже, когда будет ключ Apple (.p8)"
fi

cat > "$BASE/sygnal/sygnal.yaml" <<EOF
# Создано setup-push-server.sh — правки вручную перезапишутся при следующем запуске скрипта
log:
  # при своём разделе log Sygnal не подставляет настройки журнала по умолчанию — указываем их полностью
  setup:
    version: 1
    disable_existing_loggers: false
    formatters:
      normal:
        format: "%(asctime)s [%(process)d] %(levelname)-5s %(name)s %(message)s"
    handlers:
      stderr:
        class: logging.StreamHandler
        formatter: normal
        stream: ext://sys.stderr
    loggers:
      sygnal.access:
        propagate: false
        handlers: [stderr]
        level: INFO
      sygnal:
        propagate: false
        handlers: [stderr]
    root:
      handlers: [stderr]
      level: INFO
  access:
    x_forwarded_for: true
http:
  bind_addresses: ['0.0.0.0']
  port: 5000
apps:${APPS}
EOF
[ -n "$APPS" ] || sed -i 's/^apps:$/apps: {}/' "$BASE/sygnal/sygnal.yaml"

say "HTTPS (Caddy)"
{
  echo "{"
  echo "  email $EMAIL"
  echo "}"
  echo
  echo "$PUSH_DOMAIN {"
  echo "  # наружу — только протокол шлюза Matrix и проверка работы"
  echo "  handle /_matrix/push/v1/notify {"
  echo "    reverse_proxy sygnal:5000"
  echo "  }"
  echo "  handle /health {"
  echo "    reverse_proxy sygnal:5000"
  echo "  }"
  echo "  handle {"
  echo "    respond \"Lastochka push gateway\" 200"
  echo "  }"
  echo "}"
  if [ -n "$PETS_DOMAIN" ]; then
    echo
    echo "$PETS_DOMAIN {"
    echo "  # сервер «Хвостиков»: контейнер pets-api в сети web, порт 8080"
    echo "  reverse_proxy pets-api:8080"
    echo "}"
  fi
} > "$BASE/caddy/Caddyfile"

SYGNAL_ON=0
[ -n "$APPS" ] && SYGNAL_ON=1
{
  echo "services:"
  if [ "$SYGNAL_ON" = 1 ]; then
    echo "  sygnal:"
    echo "    image: $SYGNAL_IMAGE"
    echo "    restart: unless-stopped"
    echo "    environment:"
    echo "      - SYGNAL_CONF=/data/sygnal.yaml"
    echo "    volumes:"
    echo "      - ./sygnal:/data:ro"
    echo "    networks: [web]"
  fi
  echo "  caddy:"
  echo "    image: $CADDY_IMAGE"
  echo "    restart: unless-stopped"
  echo "    ports:"
  echo "      - \"80:80\""
  echo "      - \"443:443\""
  echo "      - \"443:443/udp\""
  echo "    volumes:"
  echo "      - ./caddy/Caddyfile:/etc/caddy/Caddyfile:ro"
  echo "      - caddy_data:/data"
  echo "      - caddy_config:/config"
  echo "    networks: [web]"
  echo "networks:"
  echo "  web:"
  echo "    external: true"
  echo "volumes:"
  echo "  caddy_data: {}"
  echo "  caddy_config: {}"
} > "$BASE/docker-compose.yml"

say "Запуск"
cd "$BASE"
docker compose pull -q
docker compose up -d --remove-orphans
docker compose exec -T caddy caddy reload --config /etc/caddy/Caddyfile >/dev/null 2>&1 || true

if [ "$SYGNAL_ON" = 1 ]; then
  say "Проверка шлюза (получение сертификата может занять до минуты)"
  ok=0
  for _ in $(seq 1 20); do
    if curl -fsS --max-time 5 "https://$PUSH_DOMAIN/health" >/dev/null 2>&1; then ok=1; break; fi
    sleep 3
  done
  if [ "$ok" = 1 ]; then
    echo "  Шлюз работает: https://$PUSH_DOMAIN/health — OK"
  else
    warn "Шлюз пока не отвечает по https://$PUSH_DOMAIN/health — проверьте DNS и журнал: cd $BASE && docker compose logs --tail 50"
  fi
fi

say "Готово"
echo "  Адрес шлюза для Ласточки:  https://$PUSH_DOMAIN/_matrix/push/v1/notify"
[ -n "$PETS_DOMAIN" ] && echo "  Адрес сервера «Хвостиков»: https://$PETS_DOMAIN  (ждёт контейнер pets-api:8080 в сети web; папка /opt/apps/pets)"
echo "  Журнал:       cd $BASE && docker compose logs -f"
echo "  Перезапуск:   cd $BASE && docker compose restart"
