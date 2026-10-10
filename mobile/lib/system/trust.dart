// Доверие к собеседникам и своим устройствам — как в Element, только строже:
// • ключ личности (master key) каждого собеседника запоминается при первой встрече;
//   если он сменился или исчез — предупреждение и запрет отправки, пока вы не подтвердите;
// • сообщения с устройств, которые владелец не подтвердил, помечаются. Устройство определяется
//   по ключу сеанса шифрования (его не подделать на сервере), а не по полям конверта;
// • новый вход в ваш аккаунт (любой, даже без шифрования) — уведомление «Это вы?».
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:matrix/encryption.dart';
import 'package:matrix/matrix.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../main.dart';

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
    client.onSync.stream.listen((s) {
      _check();
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

  void _check() {
    if (!client.isLogged() || client.prevBatch == null) return;
    var dirty = false;
    final ch = Map<String, bool>.of(changed.value);
    for (final MapEntry(key: uid, value: list) in client.userDeviceKeys.entries) {
      if (list.outdated) continue; // ключи ещё не загружены — не судим
      final mk = list.masterKey?.publicKey;
      final pinned = _pins[uid];
      if (mk == null) {
        // ключ личности был — и исчез: сервер мог его убрать, чтобы обойти проверку
        if (pinned != null && uid != client.userID && !ch.containsKey(uid)) {
          ch[uid] = _pinVerified[uid] == true;
          dirty = true;
        }
        continue;
      }
      if (pinned == null) {
        _pins[uid] = mk; // первая встреча — запоминаем
        _pinVerified[uid] = list.masterKey!.verified;
        dirty = true;
      } else if (pinned != mk) {
        if (uid == client.userID) {
          // ключ вашего аккаунта сброшен (вами в другом приложении — или кем-то ещё)
          _pins[uid] = mk;
          _pinVerified[uid] = true;
          onOwnIdentityReset?.call();
        } else if (!ch.containsKey(uid)) {
          ch[uid] = _pinVerified[uid] == true;
        }
        dirty = true;
      } else if (list.masterKey!.verified && _pinVerified[uid] != true) {
        _pinVerified[uid] = true;
        dirty = true;
      }
    }
    if (dirty) {
      changed.value = ch;
      unawaited(_save());
    }
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

  /// Принять новый ключ собеседника («Понятно»).
  Future<void> acceptChange(String userId) async {
    final mk = client.userDeviceKeys[userId]?.masterKey;
    if (mk?.publicKey != null) {
      _pins[userId] = mk!.publicKey!;
      _pinVerified[userId] = mk.verified;
    } else {
      _pins.remove(userId);
      _pinVerified.remove(userId);
    }
    changed.value = Map.of(changed.value)..remove(userId);
    await _save();
  }

  Future<void> confirmLogin(String deviceId) async {
    newLogins.value = newLogins.value.where((d) => d != deviceId).toList();
    await _save();
  }

  /// Кто в этом чате сменил ключ личности.
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
    final sess = enc.keyManager.getInboundGroupSession(e.room.id, sessionId);
    if (sess != null) {
      final w = _judgeSession(e.senderId, sess);
      _bySession[key] = w ?? '';
      return w;
    }
    if (_loading.add(key)) {
      enc.keyManager.loadInboundGroupSession(e.room.id, sessionId).then((s) {
        if (s != null) {
          _bySession[key] = _judgeSession(e.senderId, s) ?? '';
          senderChecks.value++;
        }
      }).whenComplete(() => _loading.remove(key));
    }
    return null;
  }

  /// Ключ к сообщению мог прийти не от автора, а пересылкой (по запросу ключа).
  /// Доверяем пересылке только от самого автора или от своего подтверждённого устройства.
  String? _judgeSession(String senderId, SessionKey s) {
    final chain = s.forwardingCurve25519KeyChain;
    if (chain.isNotEmpty) {
      final fwd = chain.last;
      final bySender = client.userDeviceKeys[senderId]?.deviceKeys.values.where((d) => d.curve25519Key == fwd).firstOrNull;
      if (bySender == null) {
        final mine = client.userDeviceKeys[client.userID]?.deviceKeys.values.where((d) => d.curve25519Key == fwd).firstOrNull;
        final trusted = mine != null && (mine.deviceId == client.deviceID || mine.hasValidSignatureChain(verifiedByTheirMasterKey: true));
        if (!trusted) return 'Ключ к сообщению переслало постороннее устройство — подлинность не подтверждена';
        // переслало ваше подтверждённое устройство — проверяем исходное устройство автора по его ключу подписи
        final claimed = s.senderClaimedKeys['ed25519'];
        final list = client.userDeviceKeys[senderId];
        final dk = list?.deviceKeys.values.where((d) => d.ed25519Key == claimed).firstOrNull;
        if (list == null) return null;
        if (dk == null) return 'Отправлено с устройства, которое уже удалено или неизвестно';
        return _judgeDevice(senderId, list, dk);
      }
    }
    return _judge(senderId, s.senderKey, s.senderClaimedKeys['ed25519']);
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
