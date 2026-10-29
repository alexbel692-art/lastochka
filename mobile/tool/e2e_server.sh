#!/usr/bin/env bash
# Сервер Matrix (Synapse) для автотеста интерфейса: два пользователя и группа с сообщением.
# Пишет в $GITHUB_ENV: E2E_PASS, E2E_ROOM, E2E_BOB (токен второго участника для проверки после теста).
set -euo pipefail
IMG=matrixdotorg/synapse:v1.120.2
D="$PWD/e2e-synapse"
mkdir -p "$D"
docker run --rm -v "$D:/data" -e SYNAPSE_SERVER_NAME=lastochka.test -e SYNAPSE_REPORT_STATS=no "$IMG" generate
# файлы принадлежат пользователю Synapse в контейнере — дописываем через sudo, владельца не меняем
sudo tee -a "$D/homeserver.yaml" > /dev/null <<'Y'
# автотест: без ограничений частоты запросов
rc_message: {per_second: 1000, burst_count: 1000}
rc_registration: {per_second: 1000, burst_count: 1000}
rc_login:
  address: {per_second: 1000, burst_count: 1000}
  account: {per_second: 1000, burst_count: 1000}
  failed_attempts: {per_second: 1000, burst_count: 1000}
rc_joins:
  local: {per_second: 1000, burst_count: 1000}
rc_invites:
  per_room: {per_second: 1000, burst_count: 1000}
  per_user: {per_second: 1000, burst_count: 1000}
Y
docker run -d --name synapse -p 8008:8008 -v "$D:/data" "$IMG"
for i in $(seq 1 90); do curl -sf http://localhost:8008/health >/dev/null && break; sleep 2; done
curl -sf http://localhost:8008/health >/dev/null || { docker logs synapse | tail -50; echo "::error title=Автотест::Synapse не запустился"; exit 1; }
PA="Alice-e2e-$(openssl rand -hex 6)"
PB="Bob-e2e-$(openssl rand -hex 6)"
docker exec synapse register_new_matrix_user -c /data/homeserver.yaml -u alice -p "$PA" --no-admin http://localhost:8008
docker exec synapse register_new_matrix_user -c /data/homeserver.yaml -u bob -p "$PB" --no-admin http://localhost:8008
BOB=$(curl -sf -X POST http://localhost:8008/_matrix/client/v3/login \
  -d "{\"type\":\"m.login.password\",\"identifier\":{\"type\":\"m.id.user\",\"user\":\"bob\"},\"password\":\"$PB\"}" | jq -r .access_token)
ROOM=$(curl -sf -X POST -H "Authorization: Bearer $BOB" http://localhost:8008/_matrix/client/v3/createRoom \
  -d '{"name":"Тест-группа","preset":"private_chat","invite":["@alice:lastochka.test"]}' | jq -r .room_id)
curl -sf -X PUT -H "Authorization: Bearer $BOB" "http://localhost:8008/_matrix/client/v3/rooms/$ROOM/send/m.room.message/e2e1" \
  -d '{"msgtype":"m.text","body":"Привет из автотеста"}' > /dev/null
echo "::add-mask::$PA"
echo "::add-mask::$BOB"
{
  echo "E2E_PASS=$PA"
  echo "E2E_ROOM=$ROOM"
  echo "E2E_BOB=$BOB"
} >> "$GITHUB_ENV"
echo "Synapse готов, группа $ROOM"
