// Имена участников так, чтобы под чужое имя нельзя было «замаскироваться».
//
// Отображаемое имя в Matrix каждый задаёт себе сам. В группе злоумышленник может назваться
// так же, как руководитель или коллега, — и его сообщения выглядели бы неотличимо. Поэтому,
// как в Element: если в чате два участника с одинаковым именем, к имени добавляется логин
// (а для участника с другого сервера — полный адрес, ведь логин там может совпадать).
import 'package:matrix/matrix.dart';

/// Убрать невидимые символы и «переворот» текста: «Иван\u200b» не должен считаться другим именем.
String cleanName(String s) =>
    s.replaceAll(RegExp(r'[\u0000-\u001f\u007f\u00ad\u034f\u061c\u115f\u1160\u17b4\u17b5\u180e\u200b-\u200f\u202a-\u202e\u2060-\u206f\u3164\ufe00-\ufe0f\ufeff\uffa0]'), '').trim();

/// Ключ для сравнения имён: без регистра, лишних пробелов и с латинскими двойниками русских букв
/// («Иван» с латинской «а» — тот же «Иван»).
String nameKey(String s) {
  const twins = {'a': 'а', 'e': 'е', 'o': 'о', 'p': 'р', 'c': 'с', 'x': 'х', 'y': 'у', 'k': 'к', 'm': 'м', 'h': 'н', 't': 'т', 'b': 'в', 'i': 'і'};
  final low = cleanName(s).toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
  return low.split('').map((c) => twins[c] ?? c).join();
}

final _dups = <String, (int, Set<String>)>{};

/// Имена, которые в этом чате носят сразу несколько участников (ключи [nameKey]).
Set<String> duplicateNames(Room room) {
  final members = room.getParticipants([Membership.join, Membership.invite]);
  final stamp = Object.hashAll(members.map((u) => '${u.id}\u0000${u.displayName}'));
  final hit = _dups[room.id];
  if (hit != null && hit.$1 == stamp) return hit.$2;
  final seen = <String, String>{}, dup = <String>{};
  for (final u in members) {
    final k = nameKey(u.calcDisplayname());
    if (k.isEmpty) continue;
    final other = seen[k];
    if (other != null && other != u.id) dup.add(k);
    seen[k] = u.id;
  }
  if (_dups.length > 64) _dups.remove(_dups.keys.first);
  _dups[room.id] = (stamp, dup);
  return dup;
}

/// Имя участника для показа в чате: обычное имя, а у тёзок — с логином.
String memberName(Room room, String userId, {String? name}) {
  final n = cleanName(name ?? room.unsafeGetUserFromMemoryOrFallback(userId).calcDisplayname());
  final local = userId.localpart ?? userId;
  final shown = n.isEmpty ? local : n;
  if (!duplicateNames(room).contains(nameKey(shown))) return shown;
  final mine = room.client.userID?.domain;
  return '$shown (${userId.domain == mine ? '@$local' : userId})';
}
