// Чистая логика «ключ собеседника сменился» — без Matrix и без хранилища, чтобы её можно было
// проверить автотестами (test/trust_core_test.dart).

/// Что известно о ключе личности собеседника сейчас.
class KeySnapshot {
  /// Открытый ключ личности (master key); null — ключа нет (не загружен или пропал).
  final String? masterKey;
  final bool verified;
  /// Список устройств помечен «устарел» — новые ключи ещё не скачаны.
  final bool outdated;
  const KeySnapshot(this.masterKey, {this.verified = false, this.outdated = false});
}

class TrustResult {
  final Map<String, String> pins;
  final Map<String, bool> pinVerified;
  final Map<String, bool> changed;
  final bool ownReset;
  final bool dirty;
  const TrustResult(this.pins, this.pinVerified, this.changed, {this.ownReset = false, this.dirty = false});
}

/// Отметка «ключ пропал»: любой ключ, появившийся после неё, считается сменой, а не первой встречей.
const missingKeyPin = '!none';

class TrustCore {
  TrustCore._();

  /// Сравнить текущие ключи с запомненными.
  static TrustResult evaluate({
    required Map<String, String> pins,
    required Map<String, bool> pinVerified,
    required Map<String, bool> changed,
    required Map<String, KeySnapshot> keys,
    required String myId,
  }) {
    final p = Map<String, String>.of(pins);
    final pv = Map<String, bool>.of(pinVerified);
    final ch = Map<String, bool>.of(changed);
    var dirty = false, ownReset = false;
    for (final MapEntry(key: uid, value: k) in keys.entries) {
      final pinned = p[uid];
      final mk = k.masterKey;
      if (mk == null) {
        // ключ личности был — и исчез (сервер мог убрать его, чтобы обойти проверку).
        // «Устаревший» список без ключа не судим: ключи просто ещё не скачаны
        if (!k.outdated && pinned != null && pinned != missingKeyPin && uid != myId && !ch.containsKey(uid)) {
          ch[uid] = pv[uid] == true;
          dirty = true;
        }
        continue;
      }
      if (pinned == null) {
        // первая встреча — запоминаем (но только полностью загруженный ключ)
        if (k.outdated) continue;
        p[uid] = mk;
        pv[uid] = k.verified;
        dirty = true;
      } else if (pinned != mk) {
        // сравниваем и «устаревший» список: в нём последний скачанный ключ — его смену пропускать нельзя
        if (uid == myId) {
          p[uid] = mk;
          pv[uid] = true;
          ownReset = true;
        } else if (!ch.containsKey(uid)) {
          ch[uid] = pv[uid] == true;
        }
        dirty = true;
      } else if (k.verified && pv[uid] != true) {
        pv[uid] = true;
        dirty = true;
      }
    }
    return TrustResult(p, pv, ch, ownReset: ownReset, dirty: dirty);
  }

  /// Можно ли принять смену ключа: только когда новый ключ уже есть и он тот же, что видел человек.
  static bool canAccept({required String? currentKey, required String? shownKey, required bool outdated}) =>
      currentKey != null && !outdated && (shownKey == null || shownKey == currentKey);

  /// Отправка в чат запрещена: он защищённый, а у кого-то из участников ключ сменился и не принят.
  static bool sendBlocked({required bool encrypted, required Iterable<String> members, required Map<String, bool> changed}) =>
      encrypted && changed.isNotEmpty && members.any(changed.containsKey);
}
