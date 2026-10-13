// Доверие к собеседникам и своим устройствам — как в Element, только строже:
// • ключ личности (master key) каждого собеседника запоминается при первой встрече;
//   если он сменился или исчез — предупреждение и запрет отправки, пока вы не подтвердите;
// • сообщения с устройств, которые владелец не подтвердил, помечаются. Устройство определяется
//   по ключу сеанса шифрования (его не подделать на сервере), а не по полям конверта;
// • новый вход в ваш аккаунт (любой, даже без шифрования) — уведомление «Это вы?».
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:matrix/matrix.dart';

import 'trust_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../main.dart';
import '../matrix_client.dart' show afterDeviceKeysUpdate;

/// Отправка запрещена: у собеседника сменился ключ, а вы его ещё не приняли.
class SendBlocked implements Exception {
  @override
  String toString() => 'У собеседника сменился ключ — подтвердите его в чате, прежде чем отправлять';
}

/// Единая проверка перед ЛЮБОЙ отправкой в чат (текст, файлы, голосовые, стикеры, реакции, опросы,
/// пересылка, повтор). Тест send_guard_test следит, чтобы ни одна отправка не обходила её.
void ensureCanSend(Room room) {
  if (Trust.instance.sendBlocked(room)) throw SendBlocked();
}

class Trust {
  Trust._();
  static final instance = Trust._();

  /// Собеседники, у которых сменился ключ личности (userId → был ли он подтверждён вами).
  final changed = ValueNotifier<Map<String, bool>>({});

  /// Новые входы в ваш аккаунт, которые вы ещё не подтвердили («Это я»).
  final newLogins = ValueNotifier<List<String>>([]);

  /// Обновляется, когда проверены устройства-отправители (перерисовать чат).
  final senderChecks = ValueNotifier<int>(0);

  void Function(String deviceName)? onNewLogin;
  void Function()? onOwnIdentityReset;
  final Set<String> _blockedByUs = {};

  /// Ключи сбрасываем сами на этом устройстве («Забыли секретную фразу?») — не пугать уведомлением.
  /// Действует 10 минут: позже настоящий чужой сброс снова вызовет тревогу.
  DateTime? _selfResetAt;
  bool get selfReset => _selfResetAt != null && DateTime.now().difference(_selfResetAt!).inMinutes < 10;
  set selfReset(bool v) => _selfResetAt = v ? DateTime.now() : null;

  SharedPreferences? _p;
  Map<String, String> _pins = {};
  Map<String, bool> _pinVerified = {};
  Set<String> _mySessions = {};
  bool _seeded = false;
  DateTime _lastSessionsCheck = DateTime(2000);
  bool _sessionsBusy = false;

  Future<void> init() async {
    _p = await SharedPreferences.getInstance();
    _pins = Map<String, String>.from(jsonDecode(_p!.getString('trust.pins') ?? '{}') as Map);
    _pinVerified = Map<String, bool>.from(jsonDecode(_p!.getString('trust.pinVerified') ?? '{}') as Map);
    changed.value = Map<String, bool>.from(jsonDecode(_p!.getString('trust.changed') ?? '{}') as Map);
    final my = _p!.getStringList('trust.mySessions');
    _seeded = my != null;
    _mySessions = (my ?? []).toSet();
    newLogins.value = _p!.getStringList('trust.newLogins') ?? [];
    _blockedByUs.addAll(_p!.getStringList('trust.blockedDevs') ?? const []);
    afterDeviceKeysUpdate = checkNow;
    client.onSync.stream.listen((s) {
      unawaited(checkNow());
      // список своих сеансов: при изменении своих устройств и раз в минуту
      final mineChanged = s.deviceLists?.changed?.contains(client.userID) == true;
      if (mineChanged || DateTime.now().difference(_lastSessionsCheck).inSeconds > 60) _checkSessions();
    });
  }

  Future<void> _save() async {
    await _p!.setString('trust.pins', jsonEncode(_pins));
    await _p!.setString('trust.pinVerified', jsonEncode(_pinVerified));
    await _p!.setString('trust.changed', jsonEncode(changed.value));
    await _p!.setStringList('trust.mySessions', _mySessions.toList());
    await _p!.setStringList('trust.newLogins', newLogins.value);
  }

  /// Проверить ключи сейчас. Вызывается после каждой синхронизации и — главное — сразу после того,
  /// как модуль Matrix скачал новые ключи устройств (LastochkaClient.updateUserDeviceKeys), ещё до
  /// любой отправки: окна, в котором ключ уже сменился, а проверка ещё не прошла, больше нет.
  Future<void> checkNow() async {
    _check();
    await _enforce();
  }

  void _check() {
    if (_p == null || !client.isLogged() || client.prevBatch == null) return;
    final keys = <String, KeySnapshot>{
      for (final MapEntry(key: uid, value: list) in client.userDeviceKeys.entries)
        uid: KeySnapshot(list.masterKey?.publicKey, verified: list.masterKey?.verified ?? false, outdated: list.outdated),
    };
    final r = TrustCore.evaluate(pins: _pins, pinVerified: _pinVerified, changed: changed.value, keys: keys, myId: client.userID ?? '');
    if (!r.dirty) return;
    _pins = r.pins;
    _pinVerified = r.pinVerified;
    if (r.ownReset) {
      if (selfReset) {
        selfReset = false;
      } else {
        onOwnIdentityReset?.call();
      }
    }
    changed.value = r.changed;
    unawaited(_save());
  }

  /// Устройства собеседника со сменившимся (не принятым) ключом блокируются в самом модуле шифрования:
  /// ключи сообщений и звонков им не отправляются НИ ОДНИМ путём, даже если какая-то отправка обошла проверку.
  Future<void> _enforce() async {
    final ch = changed.value;
    var dirty = false;
    for (final uid in ch.keys) {
      final list = client.userDeviceKeys[uid];
      if (list == null) continue;
      for (final d in list.deviceKeys.values) {
        if (d.blocked) continue;
        try {
          await d.setBlocked(true);
          _blockedByUs.add('$uid|${d.deviceId}');
          dirty = true;
        } catch (_) {}
      }
    }
    if (dirty) await _p?.setStringList('trust.blockedDevs', _blockedByUs.toList());
  }

  /// Снять блокировку, которую ставили мы (после «Понятно» или подтверждения собеседника).
  Future<void> _unblock(String uid) async {
    final list = client.userDeviceKeys[uid];
    final mine = _blockedByUs.where((k) => k.startsWith('$uid|')).toList();
    for (final k in mine) {
      final dev = k.substring(uid.length + 1);
      try {
        await list?.deviceKeys[dev]?.setBlocked(false);
      } catch (_) {}
      _blockedByUs.remove(k);
    }
    await _p?.setStringList('trust.blockedDevs', _blockedByUs.toList());
  }

  /// Новые входы в аккаунт — по списку сеансов сервера (видны и входы без шифрования).
  Future<void> _checkSessions() async {
    if (_sessionsBusy || !client.isLogged()) return;
    _sessionsBusy = true;
    _lastSessionsCheck = DateTime.now();
    try {
      final devices = await client.getDevices() ?? [];
      final ids = devices.map((d) => d.deviceId).toSet();
      if (!_seeded) {
        _mySessions = ids; // первый запуск — все текущие считаем своими
        _seeded = true;
      } else {
        final fresh = ids.difference(_mySessions).where((id) => id != client.deviceID).toList();
        _mySessions.addAll(fresh);
        if (fresh.isNotEmpty) {
          newLogins.value = [...newLogins.value, ...fresh];
          for (final id in fresh) {
            final d = devices.firstWhere((x) => x.deviceId == id);
            onNewLogin?.call(d.displayName ?? id);
          }
        }
        final still = newLogins.value.where(ids.contains).toList();
        if (still.length != newLogins.value.length) newLogins.value = still;
      }
      await _save();
    } catch (_) {
    } finally {
      _sessionsBusy = false;
    }
  }

  /// После выхода из аккаунта: список своих сеансов начнётся заново.
  Future<void> resetOwnDevices() async {
    _mySessions = {};
    _seeded = false;
    newLogins.value = [];
    await _p?.remove('trust.mySessions');
    await _p?.remove('trust.newLogins');
  }

  /// Ключ личности собеседника сейчас (для показа и для подтверждения «Понятно» именно этого ключа).
  String? currentKey(String userId) => client.userDeviceKeys[userId]?.masterKey?.publicKey;

  /// Принять новый ключ собеседника («Понятно»). Только если новый ключ уже получен и это тот самый
  /// ключ, который человек видел на экране ([shownKey]). Ключ пропал или ещё не загружен — нельзя:
  /// иначе можно было бы снять блокировку, а потом подложить чужой ключ «как первый».
  Future<bool> acceptChange(String userId, {String? shownKey}) async {
    final list = client.userDeviceKeys[userId];
    final mk = list?.masterKey;
    if (!TrustCore.canAccept(currentKey: mk?.publicKey, shownKey: shownKey, outdated: list?.outdated ?? true)) return false;
    _pins[userId] = mk!.publicKey!;
    _pinVerified[userId] = mk.verified;
    changed.value = Map.of(changed.value)..remove(userId);
    await _save();
    await _unblock(userId);
    return true;
  }

  Future<void> confirmLogin(String deviceId) async {
    newLogins.value = newLogins.value.where((d) => d != deviceId).toList();
    await _save();
  }

  /// Кто в этом чате сменил ключ личности.
  /// В чате есть собеседник со сменившимся ключом, которого вы ещё не приняли, — отправлять туда нельзя
  /// ни одним способом (ветка, пересылка, отложенные, повтор неотправленных).
  bool sendBlocked(Room room) {
    final c = changed.value;
    if (c.isEmpty || !room.encrypted) return false;
    // и загруженные участники, и все, чьи ключи известны модулю шифрования для этого чата
    final members = room.getParticipants([Membership.join, Membership.invite]).map((u) => u.id).toSet();
    return TrustCore.sendBlocked(encrypted: room.encrypted, members: members, changed: c) ||
        (c.keys.any((u) => room.summary.mHeroes?.contains(u) == true));
  }

  List<String> changedIn(Room room) {
    final c = changed.value;
    if (c.isEmpty) return const [];
    return room.getParticipants([Membership.join, Membership.invite]).map((u) => u.id).where(c.containsKey).toList();
  }

  // результат проверки по сеансу шифрования: sessionId → предупреждение ('' — всё в порядке)
  final Map<String, String> _bySession = {};
  final Set<String> _loading = {};

  /// Проверка устройства, с которого пришло зашифрованное сообщение.
  /// null — всё в порядке (или ещё проверяется); иначе текст предупреждения.
  String? senderWarning(Event e) {
    final src = e.originalSource;
    if (src == null || src.type != EventTypes.Encrypted) return null;
    if (e.type == EventTypes.Encrypted) return null; // ещё не расшифровано — отдельная надпись
    final sessionId = src.content['session_id'];
    if (sessionId is! String) return null;
    final key = '${e.room.id}|$sessionId|${e.senderId}';
    final cached = _bySession[key];
    if (cached != null) return cached.isEmpty ? null : cached;
    final enc = client.encryption;
    if (enc == null) return null;
    // списки устройств ещё не загружены — не судим (и не запоминаем), иначе ложная тревога
    final sl = client.userDeviceKeys[e.senderId], ml = client.userDeviceKeys[client.userID];
    if (sl == null || sl.outdated || ml == null) return null;
    final sess = enc.keyManager.getInboundGroupSession(e.room.id, sessionId);
    if (sess != null) {
      final w = _judgeSession(e.senderId, sess.forwardingCurve25519KeyChain, sess.senderKey, sess.senderClaimedKeys);
      _bySession[key] = w ?? '';
      return w;
    }
    if (_loading.add(key)) {
      enc.keyManager.loadInboundGroupSession(e.room.id, sessionId).then((s) {
        if (s != null && client.userDeviceKeys[e.senderId] != null) {
          _bySession[key] = _judgeSession(e.senderId, s.forwardingCurve25519KeyChain, s.senderKey, s.senderClaimedKeys) ?? '';
          senderChecks.value++;
        }
      }).whenComplete(() => _loading.remove(key));
    }
    return null;
  }

  /// Ключ к сообщению мог прийти не от автора, а пересылкой (по запросу ключа).
  /// Доверяем пересылке только от самого автора или от своего подтверждённого устройства.
  String? _judgeSession(String senderId, List<String> chain, String senderKey, Map<String, String> claimed) {
    if (chain.isNotEmpty) {
      final fwd = chain.last;
      final bySender = client.userDeviceKeys[senderId]?.deviceKeys.values.where((d) => d.curve25519Key == fwd).firstOrNull;
      if (bySender == null) {
        final mine = client.userDeviceKeys[client.userID]?.deviceKeys.values.where((d) => d.curve25519Key == fwd).firstOrNull;
        if (mine == null) {
          // переславшего устройства уже нет (например, ключ из резервной копии старого устройства)
          return 'Ключ получен с устройства, которого уже нет, — подлинность не гарантируется';
        }
        final trusted = mine.deviceId == client.deviceID || mine.hasValidSignatureChain(verifiedByTheirMasterKey: true);
        if (!trusted) return 'Ключ к сообщению переслало неподтверждённое устройство — подлинность не подтверждена';
        // переслало ваше подтверждённое устройство — дальше проверяем исходное устройство автора
      }
    }
    return _judge(senderId, senderKey, claimed['ed25519']);
  }

  String? _judge(String senderId, String senderKey, String? claimedEd25519) {
    final list = client.userDeviceKeys[senderId];
    if (list == null) return null;
    final dk = list.deviceKeys.values.where((d) => d.curve25519Key == senderKey).firstOrNull;
    if (dk == null) return 'Отправлено с устройства, которое уже удалено или неизвестно';
    if (claimedEd25519 != null && dk.ed25519Key != claimedEd25519) return 'Ключ устройства не совпадает — подлинность не подтверждена';
    return _judgeDevice(senderId, list, dk);
  }

  String? _judgeDevice(String senderId, DeviceKeysList list, DeviceKeys dk) {
    if (senderId == client.userID && dk.deviceId == client.deviceID) return null;
    if (list.masterKey == null) {
      // ключа личности нет: если раньше был — это подозрительно (см. changed), иначе просто нет защиты
      return _pins.containsKey(senderId) ? 'Ключ личности отправителя пропал — подлинность не подтверждена' : null;
    }
    if (!dk.hasValidSignatureChain(verifiedByTheirMasterKey: true)) {
      return 'Отправлено с устройства, которое владелец не подтвердил';
    }
    return null;
  }

  /// Подтверждён ли собеседник вами (сравнение эмодзи).
  bool userVerified(String userId) => client.userDeviceKeys[userId]?.masterKey?.verified == true;
}
