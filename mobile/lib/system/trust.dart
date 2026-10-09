// Доверие к собеседникам и своим устройствам — как в Element, только строже:
// • ключ личности (master key) каждого собеседника запоминается при первой встрече;
//   если он сменился — предупреждение и запрет отправки, пока вы не подтвердите;
// • сообщения с устройств, которые владелец не подтвердил, помечаются;
// • новый вход в ваш аккаунт — уведомление «Это вы?».
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
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

  void Function(String deviceName)? onNewLogin;

  SharedPreferences? _p;
  Map<String, String> _pins = {};
  Map<String, bool> _pinVerified = {};
  Set<String> _myDevices = {};
  bool _seeded = false;

  Future<void> init() async {
    _p = await SharedPreferences.getInstance();
    _pins = Map<String, String>.from(jsonDecode(_p!.getString('trust.pins') ?? '{}') as Map);
    _pinVerified = Map<String, bool>.from(jsonDecode(_p!.getString('trust.pinVerified') ?? '{}') as Map);
    changed.value = Map<String, bool>.from(jsonDecode(_p!.getString('trust.changed') ?? '{}') as Map);
    final my = _p!.getStringList('trust.myDevices');
    _seeded = my != null;
    _myDevices = (my ?? []).toSet();
    newLogins.value = _p!.getStringList('trust.newLogins') ?? [];
    client.onSync.stream.listen((_) => _check());
  }

  Future<void> _save() async {
    await _p!.setString('trust.pins', jsonEncode(_pins));
    await _p!.setString('trust.pinVerified', jsonEncode(_pinVerified));
    await _p!.setString('trust.changed', jsonEncode(changed.value));
    await _p!.setStringList('trust.myDevices', _myDevices.toList());
    await _p!.setStringList('trust.newLogins', newLogins.value);
  }

  void _check() {
    if (!client.isLogged() || client.prevBatch == null) return;
    var dirty = false;
    final ch = Map<String, bool>.of(changed.value);
    for (final MapEntry(key: uid, value: list) in client.userDeviceKeys.entries) {
      final mk = list.masterKey?.publicKey;
      if (mk == null) continue;
      final pinned = _pins[uid];
      if (pinned == null) {
        _pins[uid] = mk; // первая встреча — запоминаем
        _pinVerified[uid] = list.masterKey!.verified;
        dirty = true;
      } else if (pinned != mk) {
        // ключ личности сменился: сброс аккаунта, новый вход без ключа восстановления — или подмена
        if (uid != client.userID && !ch.containsKey(uid)) ch[uid] = _pinVerified[uid] == true;
        if (uid == client.userID) {
          _pins[uid] = mk; // свой сброс делаем сами — запоминаем новый
          _pinVerified[uid] = true;
        }
        dirty = true;
      } else if (list.masterKey!.verified && _pinVerified[uid] != true) {
        _pinVerified[uid] = true;
        dirty = true;
      }
    }
    if (dirty || ch.length != changed.value.length) changed.value = ch;

    // новые входы в свой аккаунт
    final mine = client.userDeviceKeys[client.userID]?.deviceKeys;
    if (mine != null && mine.isNotEmpty) {
      final ids = mine.keys.toSet();
      if (!_seeded) {
        _myDevices = ids; // первый запуск — все текущие считаем своими
        _seeded = true;
        dirty = true;
      } else {
        final fresh = ids.difference(_myDevices).where((id) => id != client.deviceID).toList();
        if (fresh.isNotEmpty) {
          _myDevices.addAll(fresh);
          newLogins.value = [...newLogins.value, ...fresh];
          for (final id in fresh) {
            onNewLogin?.call(mine[id]?.deviceDisplayName ?? id);
          }
          dirty = true;
        }
        // удалённые сеансы убираем из списка «новых»
        final still = newLogins.value.where(ids.contains).toList();
        if (still.length != newLogins.value.length) {
          newLogins.value = still;
          dirty = true;
        }
      }
    }
    if (dirty) unawaited(_save());
  }

  /// После выхода из аккаунта: список своих устройств начнётся заново.
  Future<void> resetOwnDevices() async {
    _myDevices = {};
    _seeded = false;
    newLogins.value = [];
    await _p?.remove('trust.myDevices');
    await _p?.remove('trust.newLogins');
  }

  /// Принять новый ключ собеседника («Понятно»).
  Future<void> acceptChange(String userId) async {
    final mk = client.userDeviceKeys[userId]?.masterKey;
    if (mk?.publicKey != null) {
      _pins[userId] = mk!.publicKey!;
      _pinVerified[userId] = mk.verified;
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

  /// Проверка устройства, с которого пришло зашифрованное сообщение.
  /// null — всё в порядке; иначе текст предупреждения.
  String? senderWarning(Event e) {
    final src = e.originalSource;
    if (src == null || src.type != EventTypes.Encrypted) return null;
    if (e.type == EventTypes.Encrypted) return null; // ещё не расшифровано — отдельная надпись
    final senderKey = src.content['sender_key'];
    final deviceId = src.content['device_id'];
    final list = client.userDeviceKeys[e.senderId];
    if (list == null) return null;
    DeviceKeys? dk;
    if (deviceId is String) dk = list.deviceKeys[deviceId];
    if (dk == null && senderKey is String) {
      dk = list.deviceKeys.values.where((d) => d.curve25519Key == senderKey).firstOrNull;
    }
    if (dk == null) return 'Отправлено с устройства, которое уже удалено или неизвестно';
    if (senderKey is String && dk.curve25519Key != senderKey) return 'Ключ устройства не совпадает — подлинность не подтверждена';
    if (e.senderId == client.userID && dk.deviceId == client.deviceID) return null;
    if (list.masterKey != null && !dk.signed) return 'Отправлено с устройства, которое владелец не подтвердил';
    return null;
  }

  /// Подтверждён ли собеседник вами (сравнение эмодзи).
  bool userVerified(String userId) => client.userDeviceKeys[userId]?.masterKey?.verified == true;
}
