// Поиск сообщений во всех чатах. Сервер зашифрованные сообщения искать не умеет,
// поэтому ищем на устройстве — по уже расшифрованной истории (и подгружаем немного старой).
import 'package:matrix/matrix.dart';

import '../main.dart';
import 'autodelete.dart';
import 'formatting.dart';

class SearchHit {
  final Room room;
  final Event event;
  final String text;
  SearchHit(this.room, this.event, this.text);
}

class GlobalSearch {
  int _gen = 0;

  void cancel() => _gen++;

  /// Найденное приходит порциями: [onHits] вызывается после каждого чата.
  Future<void> run(String query, void Function(List<SearchHit> hits, bool done) onHits) async {
    final gen = ++_gen;
    final q = query.trim().toLowerCase();
    final all = <SearchHit>[];
    if (q.length < 3) return onHits(all, true);
    final rooms = client.rooms.where((r) => r.membership == Membership.join).toList()
      ..sort((a, b) => (b.lastEvent?.originServerTs ?? DateTime(2000)).compareTo(a.lastEvent?.originServerTs ?? DateTime(2000)));
    for (var i = 0; i < rooms.length; i++) {
      if (gen != _gen) return;
      final room = rooms[i];
      Timeline? tl;
      try {
        tl = await room.getTimeline();
        // у самых активных чатов дополнительно подгружаем историю
        for (var k = 0; k < (i < 10 ? 2 : 0) && tl.canRequestHistory; k++) {
          if (gen != _gen) return;
          await tl.requestHistory(historyCount: 100);
        }
        for (final e in tl.events) {
          if (e.type != EventTypes.Message || e.redacted || isExpired(e) || e.relationshipType == RelationshipTypes.edit) continue;
          final d = e.getDisplayEvent(tl);
          final mt = d.messageType;
          if (mt != MessageTypes.Text && mt != MessageTypes.Notice && mt != MessageTypes.Emote && mt != MessageTypes.File) continue;
          final text = stripMarkdown(d.calcUnlocalizedBody(hideReply: true));
          if (text.toLowerCase().contains(q)) all.add(SearchHit(room, e, text));
        }
      } catch (_) {
      } finally {
        tl?.cancelSubscriptions();
      }
      if (gen != _gen) return;
      all.sort((a, b) => b.event.originServerTs.compareTo(a.event.originServerTs));
      onHits(List.of(all.take(200)), i == rooms.length - 1);
    }
    if (rooms.isEmpty) onHits(all, true);
  }
}
