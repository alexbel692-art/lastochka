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
  if (!client.encryptionEnabled && !Trust.instance.debugAllowNoEncryption) {
    throw const SendBlocked('Шифрование на этом устройстве не работает — отправка в защищённые чаты запрещена. Перезапустите Ласточку');
  }
  if (Trust.instance.rotationPending.contains(room.id)) {
    throw const SendBlocked('Шифрование этого чата обновляется — отправка возобновится автоматически, попробуйте через минуту');
  }
  throw const SendBlocked();
}

/// Чем закончилось принятие нового ключа собеседника.
enum AcceptResult {
  /// не принят (ключ не тот / не загружен / не удалось сохранить состояние) — запрет остаётся
  refused,
  /// принят, но сеансы шифрования ещё заменяются — чаты с ним заблокированы до окончания замены
  rotating,
  /// принят, сеансы заменены — можно писать
  done,
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
    _rotatePending.addAll(_p!.getStringList('trust.rotatePending') ?? const []);
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

  /// Записать состояние доверия. Проверяется результат КАЖДОЙ записи (хранилище может вернуть false
  /// без исключения) — не записалось хоть что-то, значит не записалось ничего.
  Future<void> _save() async {
    final p = _p!;
    final ok = [
      await p.setString('trust.pins', jsonEncode(_pins)),
      await p.setString('trust.pinVerified', jsonEncode(_pinVerified)),
      await p.setString('trust.changed', jsonEncode(_changed)),
      await p.setStringList('trust.mySessions', _mySessions.toList()),
      await p.setStringList('trust.newLogins', newLogins.value),
    ];
    if (ok.contains(false)) throw StateError('хранилище не подтвердило запись');
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
    await _retryRotations();
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
    final rk = message['room_id'];
    if (rk is String && _rotatePending.contains(rk)) return devices.where((d) => d.userId == me).toList();
    final c = _changed;
    if (c.isEmpty) return devices;
    bool exempt(DeviceKeys d) {
      if (!_verifying.containsKey(d.userId)) return false;
      // Сравнение эмодзи с собеседником идёт сообщениями в личном чате, а не личными сообщениями
      // устройствам, поэтому событиям проверки исключение здесь не нужно: им — ничего, кроме ключа
      // сеанса ТОГО личного чата, где идёт проверка (иначе он не прочтёт сами события проверки).
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
  Future<void> guardRoomSend(String roomId, RoomSendInfo what) async {
    final room = client.getRoomById(roomId);
    if (room == null) {
      // чат неизвестен — не можем проверить ни шифрование, ни участников: не отправляем (fail-closed)
      throw MatrixException.fromJson({'errcode': 'M_FORBIDDEN', 'error': 'Ласточка: неизвестный чат — отправка не проверена'});
    }
    if (room.encrypted && !client.encryptionEnabled && !debugAllowNoEncryption) {
      // без работающего модуля шифрования модуль Matrix отправил бы сообщение в защищённый чат ОТКРЫТЫМ текстом
      throw MatrixException.fromJson({'errcode': 'M_FORBIDDEN', 'error': 'Ласточка: шифрование не работает — отправка в защищённый чат запрещена'});
    }
    if (room.encrypted) await _ensureKeysKnown(room);
    if (_rotatePending.contains(roomId)) {
      throw MatrixException.fromJson({'errcode': 'M_FORBIDDEN', 'error': 'Ласточка: сеанс шифрования не обновлён'});
    }
    if (!sendBlocked(room)) return;
    if (_verifyingRoom(room) && isVerificationEvent(what.type, what.msgtype)) return;
    throw MatrixException.fromJson({
      'errcode': 'M_FORBIDDEN',
      'error': _checkFailed ? 'Ласточка: проверка ключей не удалась' : 'Ласточка: у собеседника сменился ключ',
    });
  }

  /// Отсутствие данных — не разрешение: перед отправкой в защищённый чат список участников должен быть
  /// полным, а ключи всех участников, чей ключ личности мы уже знаем, — свежими (иначе смену ключа можно
  /// было бы «спрятать», не отдавая новый список устройств). Недостающее догружаем; не вышло — запрет.
  /// Совсем новые собеседники (ключ ещё не запоминали) не мешают: их ключ запомнится при первой загрузке,
  /// а без загруженных ключей модуль шифрования им всё равно ничего не отправит.
  Future<void> _ensureKeysKnown(Room room) async {
    Never stop(String why) => throw MatrixException.fromJson({'errcode': 'M_FORBIDDEN', 'error': 'Ласточка: $why'});
    try {
      await room.requestParticipants([Membership.join, Membership.invite]);
    } catch (_) {
      stop('список участников чата не загружен');
    }
    Set<String> unknown() => {
          for (final u in _membersOf(room))
            if (_pins.containsKey(u) && (client.userDeviceKeys[u]?.outdated ?? true)) u,
        };
    var miss = unknown();
    if (miss.isNotEmpty) {
      try {
        await client.updateUserDeviceKeys(additionalUsers: miss);
      } catch (_) {}
      refresh();
      miss = unknown();
    }
    if (miss.isNotEmpty) stop('ключи участников ещё не загружены');
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
  /// Проверка начинается только после успешной замены сеансов шифрования с ним (иначе — исключение
  /// [SendBlocked], проверка не начинается). Если он так и не подтверждён — сеансы заменяются снова, чтобы
  /// устройства, получившие ключи во время проверки, не прочли дальнейшую переписку; пока замена не удалась,
  /// отправка в эти чаты запрещена, а замена повторяется после каждой синхронизации и после перезапуска.
  Future<T> whileVerifying<T>(String userId, Future<T> Function() run) async {
    if (userId == client.userID) return run();
    final first = !_verifying.containsKey(userId);
    // сначала новый сеанс шифрования, и только потом — исключение для проверки
    if (first && _changed.containsKey(userId) && await _rotateRooms(_roomsWith(userId)) != true) {
      throw const SendBlocked('Не удалось обновить шифрование чата — сравнение эмодзи не начато. Попробуйте ещё раз через минуту');
    }
    _verifying.update(userId, (n) => n + 1, ifAbsent: () => 1);
    try {
      return await run();
    } finally {
      final n = (_verifying[userId] ?? 1) - 1;
      if (n > 0) {
        _verifying[userId] = n;
      } else {
        _verifying.remove(userId);
        // даже если отметку на диск записать не удалось — в памяти чаты остаются заблокированными
        if (_changed.containsKey(userId)) await _rotateRooms(_roomsWith(userId), keepIfNotSaved: true);
      }
    }
  }

  /// Чаты, где замена сеанса шифрования ещё не подтверждена: туда ничего не отправляется, их ключи
  /// никому, кроме своих устройств, не раздаются; замена повторяется после каждой синхронизации.
  /// Отметка записывается на диск ДО того, как что-либо разблокируется, и переживает перезапуск.
  final Set<String> _rotatePending = {};
  Set<String> get rotationPending => Set.unmodifiable(_rotatePending);

  /// Отметка о незавершённых заменах точно лежит на диске. Пока нет — ни одна замена не начинается
  /// (чаты при этом заблокированы в памяти), запись повторяется перед каждой попыткой.
  bool _pendingSaved = true;

  /// Только для тестов: разрешить работу без модуля шифрования (в обычных тестах его нет).
  /// В приложении без шифрования отправка в защищённые чаты запрещена, а замена сеанса не «успешна».
  @visibleForTesting
  bool debugAllowNoEncryption = false;

  /// Только для тестов: смоделировать сбой замены сеанса шифрования / записи на диск.
  @visibleForTesting
  bool debugFailRotation = false;
  @visibleForTesting
  bool debugFailStorage = false;

  /// Все, кого считаем участниками чата, — ОДИН способ и для запрета отправки, и для замены сеансов:
  /// загруженные участники (вошедшие и приглашённые), «герои» из сводки сервера и собеседник личного чата.
  Set<String> _membersOf(Room room) => {
        ...room.getParticipants([Membership.join, Membership.invite]).map((u) => u.id),
        ...?room.summary.mHeroes,
        if (room.directChatMatrixID != null) room.directChatMatrixID!,
      };

  /// Защищённые чаты, где есть этот собеседник.
  List<String> _roomsWith(String userId) =>
      [for (final r in client.rooms) if (r.encrypted && _membersOf(r).contains(userId)) r.id];

  Future<bool> _persistPending() async {
    try {
      if (debugFailStorage) throw StateError('хранилище: тестовый сбой');
      final p = _p;
      if (p == null) return _pendingSaved = false;
      return _pendingSaved = await p.setStringList('trust.rotatePending', _rotatePending.toList());
    } catch (e, s) {
      Logs().e('[Ласточка] Не удалось сохранить отметку о замене сеансов шифрования', e, s);
      return _pendingSaved = false;
    }
  }

  /// Заменить исходящие сеансы в этих чатах. Сначала чаты помечаются (на диске) как ждущие замены — и
  /// этим блокируются; отметка снимается с каждого чата только после подтверждённой замены.
  /// null — отметку записать не удалось (ничего не начато; с [keepIfNotSaved] блокировка остаётся в памяти),
  /// true — все сеансы заменены, false — часть ещё ждёт (повтор после синхронизации).
  Future<bool?> _rotateRooms(Iterable<String> roomIds, {bool keepIfNotSaved = false}) async {
    final ids = roomIds.toList();
    final add = ids.where((r) => !_rotatePending.contains(r)).toList();
    if (add.isNotEmpty) {
      _rotatePending.addAll(add);
      if (!await _persistPending()) {
        // защитное состояние не записано — замену НЕ начинаем; с keepIfNotSaved чаты остаются
        // заблокированными в памяти, запись и замена повторятся после следующей синхронизации
        if (!keepIfNotSaved) _rotatePending.removeAll(add);
        return null;
      }
    }
    var ok = true;
    for (final r in ids) {
      if (!await _rotateRoom(r)) ok = false;
    }
    return ok;
  }

  Future<bool> _rotateRoom(String roomId) async {
    final enc = client.encryption;
    try {
      if (debugFailRotation) throw StateError('замена сеанса: тестовый сбой');
      // отметка о замене должна лежать на диске до начала замены
      if (!_pendingSaved && !await _persistPending()) throw StateError('отметка о замене не записана');
      if (enc == null || !client.encryptionEnabled) {
        // модуль шифрования не работает — подтвердить замену нечем: это не успех
        if (!debugAllowNoEncryption) throw StateError('модуль шифрования недоступен');
      } else {
        await enc.keyManager.clearOrUseOutboundGroupSession(roomId, wipe: true);
        // проверяем результат, а не только отсутствие ошибки
        if (enc.keyManager.getOutboundGroupSession(roomId)?.outboundGroupSession != null) {
          throw StateError('старый сеанс шифрования остался');
        }
      }
      // снять отметку; не записалось — чат останется помеченным и после перезапуска замена просто повторится
      if (_rotatePending.remove(roomId)) await _persistPending();
      return true;
    } catch (e, s) {
      Logs().e('[Ласточка] Не удалось заменить сеанс шифрования — отправка в чат приостановлена', e, s);
      return false;
    }
  }

  @visibleForTesting
  Future<bool> debugRotateRoom(String roomId) => _rotateRoom(roomId);

  Future<void> _retryRotations() async {
    for (final rid in _rotatePending.toList()) {
      await _rotateRoom(rid);
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
  Future<AcceptResult> acceptChange(String userId, {String? shownKey}) async {
    final list = client.userDeviceKeys[userId];
    final mk = list?.masterKey;
    if (!TrustCore.canAccept(currentKey: mk?.publicKey, shownKey: shownKey, outdated: list?.outdated ?? true)) {
      return AcceptResult.refused;
    }
    // 1. Чаты с ним — сначала на диск как «ждущие замены сеанса»: так они остаются заблокированными,
    //    даже если приложение закроется на любом следующем шаге.
    final rooms = _roomsWith(userId);
    final add = rooms.where((r) => !_rotatePending.contains(r)).toList();
    _rotatePending.addAll(add);
    if (!await _persistPending()) {
      _rotatePending.removeAll(add);
      return AcceptResult.refused;
    }
    // 2. Принять ключ (тоже на диск). Не записалось — откатываем: запрет остаётся.
    final oldPin = _pins[userId], oldPv = _pinVerified[userId], oldChanged = Map.of(_changed);
    _pins[userId] = mk!.publicKey!;
    _pinVerified[userId] = mk.verified;
    _setChanged(Map.of(_changed)..remove(userId));
    if (!await _saveSafe()) {
      if (oldPin == null) {
        _pins.remove(userId);
      } else {
        _pins[userId] = oldPin;
      }
      if (oldPv == null) {
        _pinVerified.remove(userId);
      } else {
        _pinVerified[userId] = oldPv;
      }
      _setChanged(oldChanged);
      return AcceptResult.refused;
    }
    // 3. Новые сеансы шифрования; чат разблокируется только после подтверждённой замены.
    var ok = true;
    for (final r in rooms) {
      if (!await _rotateRoom(r)) ok = false;
    }
    return ok ? AcceptResult.done : AcceptResult.rotating;
  }

  Future<bool> _saveSafe() async {
    try {
      if (debugFailStorage) throw StateError('хранилище: тестовый сбой');
      await _save();
      return true;
    } catch (e, s) {
      Logs().e('[Ласточка] Не удалось сохранить состояние доверия', e, s);
      return false;
    }
  }

  /// Принять ключ, подтверждённый сравнением эмодзи. [startedKey] — ключ личности собеседника,
  /// зафиксированный ДО начала проверки: принимается только если сравнение подтвердило именно его
  /// (он помечен подтверждённым) и он же остаётся текущим. Сменился во время проверки — не принимаем.
  Future<AcceptResult> acceptVerified(String userId, String? startedKey) async {
    final mk = client.userDeviceKeys[userId]?.masterKey;
    if (startedKey == null || mk == null || mk.publicKey != startedKey || !mk.verified) return AcceptResult.refused;
    return acceptChange(userId, shownKey: startedKey);
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
    if (!client.encryptionEnabled && !debugAllowNoEncryption) return true;
    refresh();
    if (_checkFailed || _rotatePending.contains(room.id)) return true;
    final c = _changed;
    if (c.isEmpty) return false;
    return TrustCore.sendBlocked(encrypted: room.encrypted, members: _membersOf(room), changed: c);
  }

  List<String> changedIn(Room room) {
    final c = _changed;
    if (c.isEmpty) return const [];
    return _membersOf(room).where(c.containsKey).toList();
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
  @visibleForTesting
  String? debugJudgeSession(String senderId, List<String> chain, String senderKey, Map<String, String> claimed) =>
      _judgeSession(senderId, chain, senderKey, claimed);

  String? _judgeSession(String senderId, List<String> chain, String senderKey, Map<String, String> claimed) {
    if (chain.isNotEmpty) {
      final fwd = chain.last;
      final bySender = client.userDeviceKeys[senderId]?.deviceKeys.values.where((d) => d.curve25519Key == fwd).firstOrNull;
      if (bySender != null) {
        // переслало другое устройство самого автора — оно тоже должно быть подтверждено владельцем
        final self = senderId == client.userID && bySender.deviceId == client.deviceID;
        if (!self && !bySender.hasValidSignatureChain(verifiedByTheirMasterKey: true)) {
          return 'Ключ к сообщению переслало неподтверждённое устройство отправителя — подлинность не подтверждена';
        }
      }
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
