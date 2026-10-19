// Отметки о прочтении собеседников.
//
// Element (и другие современные клиенты) ставит отметку с пометкой «основная лента» (thread_id: main,
// MSC3771), а Ласточка и старые клиенты — общую. Модуль Matrix хранит их отдельно: раньше Ласточка
// смотрела только на общие, и прочитанное в Element оставалось с одной галочкой.
import 'package:matrix/matrix.dart';

/// Самая поздняя отметка о прочтении каждого собеседника (без вас) — из общих и из основной ленты.
Map<String, LatestReceiptStateData> otherReadReceipts(Room room) {
  final st = room.receiptState;
  final out = <String, LatestReceiptStateData>{};
  for (final m in [st.global.otherUsers, st.mainThread?.otherUsers ?? const <String, LatestReceiptStateData>{}]) {
    for (final MapEntry(key: uid, value: r) in m.entries) {
      if (uid == room.client.userID) continue;
      final cur = out[uid];
      if (cur == null || r.ts > cur.ts) out[uid] = r;
    }
  }
  return out;
}

/// Прочитал ли кто-нибудь из собеседников всё до этого времени.
bool readByOthersSince(Room room, int ts) => otherReadReceipts(room).values.any((r) => r.ts >= ts);
