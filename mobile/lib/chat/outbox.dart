// Очередь отправки: сообщения, фото и видео, не ушедшие из-за сети, отправляются сами,
// как только связь вернулась (и ещё раз — раз в минуту на всякий случай). Порядок сохраняется.
import 'dart:async';

import 'package:matrix/matrix.dart';

import '../system/trust.dart';
import '../main.dart';
import '../system/diag.dart';

final Set<String> _rooms = {}; // чаты, где замечены неотправленные сообщения
bool _offline = false, _running = false;
Timer? _timer;

/// Отметить чат с неотправленными сообщениями (вызывает экран чата).
void outboxNote(Room room) => _rooms.add(room.id);

void startOutbox() {
  client.onSyncStatus.stream.listen((s) {
    if (s.status == SyncStatus.error) {
      _offline = true;
    } else if (s.status == SyncStatus.finished && _offline) {
      _offline = false;
      Future.delayed(const Duration(seconds: 2), retryFailed);
    }
  });
  _timer ??= Timer.periodic(const Duration(minutes: 1), (_) => retryFailed());
  Future.delayed(const Duration(seconds: 20), retryFailed);
}

/// Отправить заново всё, что не ушло.
Future<void> retryFailed() async {
  if (_running || !client.isLogged() || _offline) return;
  _running = true;
  try {
    final rooms = {
      ..._rooms,
      for (final r in client.rooms)
        if (r.lastEvent?.status.isError == true) r.id,
    };
    for (final id in rooms) {
      final room = client.getRoomById(id);
      if (room == null || room.membership != Membership.join) {
        _rooms.remove(id);
        continue;
      }
      if (Trust.instance.sendBlocked(room)) continue; // ключ собеседника сменился — не переотправляем
      final tl = await room.getTimeline();
      try {
        final failed = tl.events.where((e) => e.status.isError && e.senderId == client.userID).toList()
          ..sort((a, b) => a.originServerTs.compareTo(b.originServerTs));
        if (failed.isEmpty) _rooms.remove(id);
        for (final e in failed) {
          try {
            await e.sendAgain();
          } on FileNoLongerInCacheException {
            // файл уже не в кэше — переотправить нельзя, остаётся с красным значком
          } catch (err) {
            Diag.err('Повторная отправка', err);
            break; // сеть снова пропала — попробуем позже, не нарушая порядок
          }
        }
      } finally {
        tl.cancelSubscriptions();
      }
    }
  } catch (e) {
    Diag.err('Очередь отправки', e);
  } finally {
    _running = false;
  }
}
