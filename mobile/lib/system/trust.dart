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
import '../matrix_client.dart' show RoomSendInfo, afterDeviceKeysUpdate, beforeRoomSend, filterKeyRecipients;

/// Отправка запрещена: у собеседника сменился ключ, а вы его ещё не приняли (или проверка ключей не удалась).
class SendBlocked implements Exception {
  final String message;
  const SendBlocked([this.message = 'У собеседника сменился ключ — подтвердите его в чате, прежде чем отправлять']);
  @override
  String toString() => message;
}

/// Проверка перед отправкой в чат из интерфейса (текст, файлы, голосовые, стикеры, реакции, опросы,
/// пересылка, повтор, звонки) — с понятным сообщением человеку. Настоящий рубеж — в самом клиенте
/// Matrix (LastochkaClient.sendMessage и отбор получателей ключей): его не обойти ни одним путём.
void ensureCanSend(Room room) {
  if (!Trust.instance.sendBlocked(room)) return;
  if (Trust.instance.checkFailed) {
    throw const SendBlocked('Не удалось проверить ключи собеседников — отправка в защищённые чаты приостановлена. Попробуйте через минуту');
  }
  throw const SendBlocked();
}

class Trust {
  Trust._();
  static final instance = Trust._();

  /// Собеседники, у которых сменился ключ личности (userId → был ли он подтверждён вами) — для экрана.
  /// Проверки читают _changed: он меняется сразу, а уведомление экрана идёт после текущего кадра
  /// (проверка может случиться и во время построения экрана).
  final changed = ValueNotifier<Map<String, bool>>({});
  Map<String, bool> _changed = {};

  void _setChanged(Map<String, bool> m) {
    _changed = m;
    scheduleMicrotask(() {
      if (!mapEquals(changed.value, _changed)) changed.value = Map.of(_changed);
    });
  }

  /// Новые входы в ваш аккаунт, которые вы ещё не подтвердили («Это я»).
  final newLogins = ValueNotifier<List<String>>([]);

  /// Обновляется, когда проверены устройства-отправители (перерисовать чат).
  final senderChecks = ValueNotifier<int>(0);

  void Function(String deviceName)? onNewLogin;
  void Function()? onOwnIdentityReset;

  /// Устройства, заблокированные версией 4.19.2 (её способ защиты). Теперь защита — в самом клиенте,
  /// а эти блокировки снимаются; запись удаляется только после успешного снятия.
  final Set<String> _blockedByUs = {};

  /// Идёт сравнение эмодзи с этим собеседником (userId → вложенность): его сообщениям проверки
  /// в личном чате нужны ключи, иначе подтвердить новый ключ было бы невозможно.
  final Map<String, int> _verifying = {};

  /// Последняя проверка ключей завершилась ошибкой — до успешной проверки отправка в защищённые
  /// чаты запрещена, а ключи шифрования получают только ваши устройства (fail-closed).
  bool _checkFailed = false;
  bool get checkFailed => _checkFailed;

  /// Текущие смены ключей (для проверок и тестов).
  Map<String, bool> get changedNow => Map.unmodifiable(_changed);

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
    _changed = Map<String, bool>.from(jsonDecode(_p!.getString('trust.changed') ?? '{}') as Map);
    changed.value = Map.of(_changed);
    final my = _p!.getStringList('trust.mySessions');
    _seeded = my != null;
    _mySessions = (my ?? []).toSet();
    newLogins.value = _p!.getStringList('trust.newLogins') ?? [];
    _blockedByUs.addAll(_p!.getStringList('trust.blockedDevs') ?? const []);
    // рубежи в самом клиенте Matrix: проверка сразу после загрузки ключей, перед отправкой любого
    // сообщения на сервер и перед отправкой ключей шифрования устройствам
    afterDeviceKeysUpdate = checkNow;
    beforeRoomSend = guardRoomSend;
    filterKeyRecipients = allowedDevices;
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
    await _p!.setString('trust.changed', jsonEncode(_changed));
    await _p!.setStringList('trust.mySessions', _mySessions.toList());
    await _p!.setStringList('trust.newLogins', newLogins.value);
  }

  /// Проверить ключи сейчас — синхронно, без ожиданий. Вызывается перед каждой отправкой и раздачей
  /// ключей шифрования, поэтому окна «ключ уже сменился, а проверка ещё не прошла» нет.
  /// Ошибка проверки не скрывается: до следующей успешной проверки действует запрет (fail-closed).
  void refresh() {
    if (_p == null || !client.isLogged()) return;
    try {
      _check();
      _checkFailed = false;
    } catch (e, s) {
      // в журнал — только при переходе в запрет, а не на каждую попытку отправки
      if (!_checkFailed) Logs().e('[Ласточка] Проверка ключей собеседников не удалась — отправка приостановлена', e, s);
      _checkFailed = true;
    }
  }

  /// После каждой синхронизации и сразу после загрузки ключей устройств (LastochkaClient).
  Future<void> checkNow() async {
    refresh();
    await _releaseOldBlocks();
  }

  /// Только для тестов: смоделировать сбой проверки ключей.
  @visibleForTesting
  bool debugFailChecks = false;

  void _check() {
    if (debugFailChecks) throw StateError('проверка ключей: тестовый сбой');
    final keys = <String, KeySnapshot>{
      for (final MapEntry(key: uid, value: list) in client.userDeviceKeys.entries)
        uid: KeySnapshot(list.masterKey?.publicKey, verified: list.masterKey?.verified ?? false, outdated: list.outdated),
    };
    final r = TrustCore.evaluate(pins: _pins, pinVerified: _pinVerified, changed: _changed, keys: keys, myId: client.userID ?? '');
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
    if (!mapEquals(r.changed, _changed)) _setChanged(r.changed);
    unawaited(_save());
  }

  /// События протокола сравнения эмодзи (в личном чате запрос идёт как m.room.message с msgtype
  /// m.key.verification.request). Ничего секретного в них нет: только ключи для сверки.
  static const _verificationTypes = {
    'm.key.verification.ready',
    'm.key.verification.start',
    'm.key.verification.accept',
    'm.key.verification.key',
    'm.key.verification.mac',
    'm.key.verification.cancel',
    'm.key.verification.done',
  };

  static bool isVerificationEvent(String? type, String? msgtype) =>
      type != null &&
      (_verificationTypes.contains(type) || (type == EventTypes.Message && msgtype == EventTypes.KeyVerificationRequest));

  /// Кому можно отправить зашифрованное личное сообщение устройству (ключи сеансов, ответы на запросы
  /// ключей, сигналы звонков, события проверки). Устройства собеседника со сменившимся непринятым ключом
  /// исключаются. Единственное исключение — идущее сравнение эмодзи с ним: тогда пропускаются только
  /// события проверки и ключ сеанса ТОГО личного чата, где идёт проверка (сеанс заменяется в начале
  /// и в конце проверки). Ключи любых других чатов и пересылаемые ключи ему не уходят никогда.
  /// Проверка не удалась — сообщения получают только ваши устройства.
  List<DeviceKeys> allowedDevices(List<DeviceKeys> devices, String eventType, Map<String, dynamic> message) {
    refresh();
    final me = client.userID;
    if (_checkFailed) return devices.where((d) => d.userId == me).toList();
    final c = _changed;
    if (c.isEmpty) return devices;
    bool exempt(DeviceKeys d) {
      if (!_verifying.containsKey(d.userId)) return false;
      if (_verificationTypes.contains(eventType) || eventType == EventTypes.KeyVerificationRequest) return true;
      if (eventType == EventTypes.RoomKey) {
        final rid = message['room_id'];
        final r = rid is String ? client.getRoomById(rid) : null;
        return r != null && r.directChatMatrixID == d.userId && _verifyingRoom(r);
      }
      return false;
    }

    final out = devices.where((d) => !c.containsKey(d.userId) || exempt(d)).toList();
    if (out.length != devices.length) {
      Logs().w('[Ласточка] $eventType не отправлено ${devices.length - out.length} устройствам собеседников со сменившимся ключом');
    }
    return out;
  }

  /// Последний рубеж перед отправкой ЛЮБОГО сообщения в чат на сервер (вызывает LastochkaClient.sendMessage).
  /// Во время сравнения эмодзи в личном чате пропускаются только события проверки — не сообщения.
  /// Ошибка M_FORBIDDEN: модуль Matrix не повторяет отправку и помечает сообщение неотправленным.
  void guardRoomSend(String roomId, RoomSendInfo what) {
    final room = client.getRoomById(roomId);
    if (room == null || !sendBlocked(room)) return;
    if (_verifyingRoom(room) && isVerificationEvent(what.type, what.msgtype)) return;
    throw MatrixException.fromJson({
      'errcode': 'M_FORBIDDEN',
      'error': _checkFailed ? 'Ласточка: проверка ключей не удалась' : 'Ласточка: у собеседника сменился ключ',
    });
  }

  /// Личный чат с собеседником, с которым сейчас идёт сравнение эмодзи (там идут сообщения проверки).
  bool _verifyingRoom(Room room) {
    if (_verifying.isEmpty || _checkFailed) return false;
    final dm = room.directChatMatrixID;
    if (dm == null || !_verifying.containsKey(dm)) return false;
    final me = client.userID;
    return room.getParticipants([Membership.join, Membership.invite]).every((u) => u.id == me || u.id == dm);
  }

  /// Сравнение эмодзи с собеседником: на это время его устройства получают ключи личного чата.
  /// Если он так и не подтверждён — сеансы шифрования с ним заменяются новыми, чтобы устройства,
  /// получившие ключи во время проверки, не прочли дальнейшую переписку.
  Future<T> whileVerifying<T>(String userId, Future<T> Function() run) async {
    if (userId == client.userID) return run();
    final first = !_verifying.containsKey(userId);
    _verifying.update(userId, (n) => n + 1, ifAbsent: () => 1);
    // проверка начинается с нового сеанса шифрования: прежние сообщения личного чата им не прочитать
    if (first && _changed.containsKey(userId)) await _rotateWith(userId);
    try {
      return await run();
    } finally {
      final n = (_verifying[userId] ?? 1) - 1;
      if (n > 0) {
        _verifying[userId] = n;
      } else {
        _verifying.remove(userId);
        if (_changed.containsKey(userId)) await _rotateWith(userId);
      }
    }
  }

  /// Заменить исходящие сеансы шифрования во всех защищённых чатах с этим собеседником.
  Future<void> _rotateWith(String userId) async {
    final enc = client.encryption;
    if (enc == null) return;
    for (final r in client.rooms) {
      if (!r.encrypted) continue;
      final has = r.directChatMatrixID == userId ||
          r.getParticipants([Membership.join, Membership.invite]).any((u) => u.id == userId);
      if (!has) continue;
      try {
        await enc.keyManager.clearOrUseOutboundGroupSession(r.id, wipe: true);
      } catch (e, s) {
        Logs().e('[Ласточка] Не удалось заменить сеанс шифрования', e, s);
      }
    }
  }

  /// Снять блокировки устройств, поставленные версией 4.19.2. Запись удаляется только когда
  /// блокировка точно снята или устройства больше нет; иначе — повтор после следующей загрузки ключей.
  Future<void> _releaseOldBlocks() async {
    if (_blockedByUs.isEmpty) return;
    var dirty = false;
    for (final k in _blockedByUs.toList()) {
      final i = k.indexOf('|');
      if (i <= 0) {
        _blockedByUs.remove(k);
        dirty = true;
        continue;
      }
      final uid = k.substring(0, i), dev = k.substring(i + 1);
      final list = client.userDeviceKeys[uid];
      if (list == null || list.outdated) continue; // ключи ещё не загружены — позже
      final d = list.deviceKeys[dev];
      if (d != null && d.blocked) {
        try {
          d.blocked = false;
          await client.database.setBlockedUserDeviceKey(false, uid, dev);
        } catch (e, s) {
          d.blocked = true;
          Logs().w('[Ласточка] Не удалось снять блокировку устройства — повторим позже', e, s);
          continue;
        }
      }
      _blockedByUs.remove(k);
      dirty = true;
    }
    if (dirty) await _p?.setStringList('trust.blockedDevs', _blockedByUs.toList());
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
    _setChanged(Map.of(_changed)..remove(userId));
    await _save();
    // новые устройства собеседника пока не получали ключей — начинаем с ними новые сеансы шифрования
    await _rotateWith(userId);
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
    if (!room.encrypted) return false;
    refresh();
    if (_checkFailed) return true;
    final c = _changed;
    if (c.isEmpty) return false;
    // и загруженные участники, и все, кого сервер называет участниками в сводке чата
    final members = room.getParticipants([Membership.join, Membership.invite]).map((u) => u.id).toSet();
    return TrustCore.sendBlocked(encrypted: room.encrypted, members: members, changed: c) ||
        (c.keys.any((u) => room.summary.mHeroes?.contains(u) == true || room.directChatMatrixID == u));
  }

  List<String> changedIn(Room room) {
    final c = _changed;
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
