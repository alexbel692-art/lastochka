// Альбомы: несколько фото и видео, отправленных вместе, показываются в ленте одной сеткой (как в Telegram).
// Каждое фото — отдельное сообщение Matrix с общей меткой альбома, поэтому в других программах
// (Element и т. п.) они видны как обычные фото подряд.
import 'dart:math';

import 'package:matrix/matrix.dart';

const albumKey = 'ru.lastochka.album';
const maxAlbum = 10;

String newAlbumId() {
  final r = Random.secure();
  return List.generate(12, (_) => r.nextInt(36).toRadixString(36)).join();
}

bool _media(Event e) => !e.redacted && (e.messageType == MessageTypes.Image || e.messageType == MessageTypes.Video);

/// Сгруппировать ленту (новые сверху): из каждого альбома остаётся одно, самое новое сообщение,
/// а в [albums] по его id — все снимки альбома по порядку отправки.
(List<Event>, Map<String, List<Event>>) groupAlbums(List<Event> events) {
  final byKey = <String, List<Event>>{};
  for (final e in events) {
    final id = e.content.tryGet<String>(albumKey);
    if (id == null || !_media(e)) continue;
    (byKey['${e.senderId}|$id'] ??= []).add(e);
  }
  final albums = <String, List<Event>>{};
  final hidden = <String>{};
  for (final list in byKey.values) {
    if (list.length < 2) continue;
    albums[list.first.eventId] = list.reversed.toList();
    for (final e in list.skip(1)) {
      hidden.add(e.eventId);
    }
  }
  if (hidden.isEmpty) return (events, albums);
  return (events.where((e) => !hidden.contains(e.eventId)).toList(), albums);
}

/// Разбивка альбома на ряды: 2 → [2], 3 → [1, 2], 4 → [2, 2], 5 → [3, 2], 7 → [2, 3, 2] …
List<int> albumRows(int n) {
  if (n <= 2) return [n];
  if (n == 3) return [1, 2];
  final rows = <int>[];
  var left = n;
  while (left > 0) {
    final take = left == 4 || left == 2 ? 2 : (left % 3 == 1 ? 2 : min(3, left));
    rows.add(take);
    left -= take;
  }
  return rows;
}
