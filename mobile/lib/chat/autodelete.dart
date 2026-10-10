// Исчезающие сообщения (автоудаление) — совместимо с настольной Ласточкой.
// Таймер чата хранится в состоянии комнаты (ru.lastochka.autodelete, ttl в мс).
// Срок жизни записывается внутрь содержимого сообщения (ru.lastochka.expires) — в зашифрованных
// чатах сервер его не видит. По истечении срока сообщение сразу скрывается у всех Ласточек,
// а Ласточка отправителя удаляет его с сервера. Дополнительно ставится m.room.retention.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:matrix/matrix.dart';

import '../main.dart';

/// Тикает раз в секунду, пока на экране есть исчезающие сообщения (обновляет только их таймеры).
final ttlTick = ValueNotifier<int>(0);

const ttlStateType = 'ru.lastochka.autodelete';
const expiresKey = 'ru.lastochka.expires';
const ttlOptions = [
  (0, 'Выключено'),
  (30000, '30 секунд'),
  (300000, '5 минут'),
  (3600000, '1 час'),
  (86400000, '1 день'),
  (604800000, '1 неделя'),
  (2592000000, '1 месяц'),
];

String ttlText(int ms) {
  for (final (v, t) in ttlOptions) {
    if (v == ms) return t;
  }
  return ms > 0 ? fmtLeft(ms) : 'Выключено';
}

String fmtLeft(int ms) {
  final s = (ms / 1000).ceil().clamp(0, 1 << 31);
  if (s < 60) return '$s с';
  if (s < 3600) return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
  if (s < 86400) return '${s ~/ 3600} ч';
  return '${s ~/ 86400} дн';
}

int roomTtl(Room room) {
  final v = room.getState(ttlStateType)?.content['ttl'];
  return v is num && v > 0 ? v.toInt() : 0;
}

/// Добавка к содержимому нового сообщения: когда оно исчезнет.
Map<String, Object> ttlExtra(Room room) {
  final t = roomTtl(room);
  return t > 0 ? {expiresKey: DateTime.now().millisecondsSinceEpoch + t} : {};
}

int expiryOf(Event e) {
  final v = e.content[expiresKey];
  return v is num && v > 0 ? v.toInt() : 0;
}

bool isExpired(Event e) {
  final x = expiryOf(e);
  return x > 0 && x <= DateTime.now().millisecondsSinceEpoch;
}

Future<void> setRoomTtl(Room room, int ms) async {
  await client.setRoomStateWithKey(room.id, ttlStateType, '', ms > 0 ? {'ttl': ms} : {});
  // сервер тоже будет стирать старые сообщения, даже если отправитель офлайн
  unawaited(client
      .setRoomStateWithKey(room.id, 'm.room.retention', '', ms > 0 ? {'max_lifetime': ms < 3600000 ? 3600000 : ms} : {})
      .catchError((_) => ''));
}

/// Текст служебного сообщения о смене таймера.
String? ttlChangeText(Event e) {
  if (e.type != ttlStateType) return null;
  final who = e.senderFromMemoryOrFallback.calcDisplayname();
  final t = e.content['ttl'];
  return t is num && t > 0 ? '$who включил(а) автоудаление сообщений: ${ttlText(t.toInt())}' : '$who выключил(а) автоудаление сообщений';
}

// ---- удаление своих истёкших сообщений с сервера ----
final Set<Timeline> openTimelines = {};
final Set<String> _queued = {};
final List<Event> _queue = [];
bool _draining = false;
Timer? _sweeper;

void startAutodeleteSweeper() {
  _sweeper ??= Timer.periodic(const Duration(seconds: 5), (_) => _sweep());
}

int _tick = 0;

void _sweep() {
  if (!client.isLogged()) return;
  // раз в минуту просматриваем последние сообщения чатов с автоудалением целиком (не только последнее)
  if (++_tick % 12 == 1) _deepSweep();
  final candidates = <Event>[
    for (final r in client.rooms)
      if (r.membership == Membership.join && r.lastEvent != null) r.lastEvent!,
    for (final tl in openTimelines) ...tl.events,
  ];
  for (final e in candidates) {
    if (e.senderId != client.userID || e.redacted || !isExpired(e)) continue;
    if (e.status.isSending || e.status.isError || e.eventId.startsWith('~')) continue;
    if (_queued.add(e.eventId)) _queue.add(e);
  }
  _drain();
}

Future<void> _drain() async {
  if (_draining) return;
  _draining = true;
  while (_queue.isNotEmpty) {
    final e = _queue.removeAt(0);
    try {
      await e.room.redactEvent(e.eventId, reason: 'Автоудаление');
    } catch (err) {
      if (err is MatrixException && err.retryAfterMs != null) {
        _queue.insert(0, e);
        await Future.delayed(Duration(milliseconds: err.retryAfterMs!.clamp(1000, 30000)));
        continue;
      }
      _queued.remove(e.eventId); // нет сети и т.п. — попробуем при следующей проверке
    }
    await Future.delayed(const Duration(milliseconds: 300));
  }
  _draining = false;
}

bool _deep = false;
Future<void> _deepSweep() async {
  if (_deep) return;
  _deep = true;
  try {
    for (final r in client.rooms.where((r) => r.membership == Membership.join && roomTtl(r) > 0)) {
      try {
        final tl = await r.getTimeline();
        for (final e in tl.events) {
          if (e.senderId != client.userID || e.redacted || !isExpired(e)) continue;
          if (e.status.isSending || e.status.isError || e.eventId.startsWith('~')) continue;
          if (_queued.add(e.eventId)) _queue.add(e);
        }
        tl.cancelSubscriptions();
      } catch (_) {}
    }
    _drain();
  } finally {
    _deep = false;
  }
}
