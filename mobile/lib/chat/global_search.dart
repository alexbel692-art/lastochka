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
      try {
        // из базы на устройстве, без загрузки участников и подписок; зашифрованное — расшифровываем
        final events = await client.database.getEventList(room, limit: 1500);
        final edits = <String, Event>{};
        for (final e in events) {
          if (gen != _gen) return;
          var ev = e;
          if (ev.type == EventTypes.Encrypted && client.encryption != null) {
            try {
              ev = await client.encryption!.decryptRoomEvent(ev);
            } catch (_) {
              continue;
            }
          }
          if (ev.type != EventTypes.Message || ev.redacted || isExpired(ev)) continue;
          if (ev.relationshipType == RelationshipTypes.edit) {
            final target = ev.relationshipEventId;
            if (target != null) edits.putIfAbsent(target, () => ev); // список идёт от новых к старым
            continue;
          }
          final edit = edits[ev.eventId];
          final content = edit?.content.tryGetMap<String, Object?>('m.new_content') ?? ev.content;
          final mt = content['msgtype'];
          if (mt != MessageTypes.Text && mt != MessageTypes.Notice && mt != MessageTypes.Emote && mt != MessageTypes.File) continue;
          final body = content['body'];
          if (body is! String) continue;
          final text = stripMarkdown(body.replaceAll(RegExp(r'^(>.*\n)+\n?'), ''));
          if (text.toLowerCase().contains(q)) all.add(SearchHit(room, ev, text));
        }
      } catch (_) {}
      if (gen != _gen) return;
      all.sort((a, b) => b.event.originServerTs.compareTo(a.event.originServerTs));
      onHits(List.of(all.take(200)), i == rooms.length - 1);
    }
    if (rooms.isEmpty) onHits(all, true);
  }
}
