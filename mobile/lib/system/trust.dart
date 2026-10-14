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
  if (!client.encryptionEnabled && Trust.instance.encryptionRequired) {
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

  /// Всё состояние доверия хранится ОДНОЙ записью (одна запись в хранилище атомарна: она либо целиком
  /// старая, либо целиком новая) и после записи проверяется обратным чтением.
  static const _stateKey = 'trust.state.v2';
  static const _legacyKeys = [
    'trust.pins', 'trust.pinVerified', 'trust.changed', 'trust.mySessions', 'trust.newLogins', 'trust.blockedDevs', 'trust.rotatePending',
  ];

  // изменений в памяти — и сколько из них уже точно на диске
  int _mutations = 0, _savedMutations = 0;
  Future<bool>? _flushing;

  /// Есть изменения, ещё не записанные на диск.
  bool get unsaved => _mutations != _savedMutations;

  void _touch() => _mutations++;

  /// Копия состояния (не ссылки на живые таблицы — ею же откатываемся при неудачной записи).
  Map<String, Object?> _snapshot() => {
        'pins': Map.of(_pins),
        'pinVerified': Map.of(_pinVerified),
        'changed': Map.of(_changed),
        'rotatePending': _rotatePending.toList(),
        'blockedDevs': _blockedByUs.toList(),
        'mySessions': _seeded ? _mySessions.toList() : null,
        'newLogins': List.of(newLogins.value),
      };

  void _load(Map<String, Object?> st) {
    _pins = Map<String, String>.from((st['pins'] as Map?) ?? const {});
    _pinVerified = Map<String, bool>.from((st['pinVerified'] as Map?) ?? const {});
    _changed = Map<String, bool>.from((st['changed'] as Map?) ?? const {});
    changed.value = Map.of(_changed);
    _rotatePending
      ..clear()
      ..addAll(((st['rotatePending'] as List?) ?? const []).cast<String>());
    _blockedByUs
      ..clear()
      ..addAll(((st['blockedDevs'] as List?) ?? const []).cast<String>());
    final my = (st['mySessions'] as List?)?.cast<String>();
    _seeded = my != null;
    _mySessions = (my ?? const <String>[]).toSet();
    newLogins.value = ((st['newLogins'] as List?) ?? const []).cast<String>();
  }

  /// Записать состояние на диск и убедиться, что записалось (обратное чтение). true — на диске ровно то,
  /// что в памяти на момент записи. Пока записи не подтверждены, отправка и раздача ключей ждут.
  Future<bool> flush() async {
    while (_flushing != null) {
      await _flushing;
    }
    if (!unsaved) return true;
    final c = Completer<bool>();
    _flushing = c.future;
    var ok = false;
    try {
      final p = _p;
      final m = _mutations;
      final data = jsonEncode(_snapshot());
      if (p != null && !_fail(debugFailStorage)) {
        ok = await p.setString(_stateKey, data) && p.getString(_stateKey) == data;
      }
      if (ok) _savedMutations = m;
      if (!ok) Logs().e('[Ласточка] Состояние доверия не записалось — отправка в защищённые чаты приостановлена');
    } catch (e, s) {
      Logs().e('[Ласточка] Состояние доверия не записалось', e, s);
      ok = false;
    } finally {
      _flushing = null;
      c.complete(ok);
    }
    return ok;
  }

  Future<void> init() async {
    _p = await SharedPreferences.getInstance();
    final raw = _p!.getString(_stateKey);
    if (raw != null) {
      _load((jsonDecode(raw) as Map).cast<String, Object?>());
    } else {
      // переход со старого хранения (отдельные записи) на одну запись
      Map<String, Object?> legacy(String k) => (jsonDecode(_p!.getString(k) ?? '{}') as Map).cast<String, Object?>();
      _load({
        'pins': legacy('trust.pins'),
        'pinVerified': legacy('trust.pinVerified'),
        'changed': legacy('trust.changed'),
        'rotatePending': _p!.getStringList('trust.rotatePending'),
        'blockedDevs': _p!.getStringList('trust.blockedDevs'),
        'mySessions': _p!.getStringList('trust.mySessions'),
        'newLogins': _p!.getStringList('trust.newLogins'),
      });
      _touch();
      if (await flush()) {
        for (final k in _legacyKeys) {
          await _p!.remove(k);
        }
      }
    }
    // рубежи в самом клиенте Matrix: проверка сразу после загрузки ключей, перед отправкой любого
    // сообщения на сервер и перед отправкой ключей шифрования устройствам
    afterDeviceKeysUpdate = checkNow;
    beforeRoomSend = guardRoomSend;
    filterKeyRecipients = allowedDevicesChecked;
    client.onSync.stream.listen((s) {
      unawaited(checkNow());
      // список своих сеансов: при изменении своих устройств и раз в минуту
      final mineChanged = s.deviceLists?.changed?.contains(client.userID) == true;
      if (mineChanged || DateTime.now().difference(_lastSessionsCheck).inSeconds > 60) _checkSessions();
    });
  }

  @visibleForTesting
  String? debugPinOf(String userId) => _pins[userId];

  /// Только для тестов: перечитать состояние с диска, как после перезапуска приложения.
  @visibleForTesting
  Future<void> debugReloadFromDisk() async {
    final raw = _p!.getString(_stateKey);
    _load(raw == null ? const {} : (jsonDecode(raw) as Map).cast<String, Object?>());
    _mutations = _savedMutations = 0;
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
    if (_fail(debugFailChecks)) throw StateError('проверка ключей: тестовый сбой');
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
    // запись — сразу; а отправка и раздача ключей дождутся её подтверждения (flush в рубежах)
    _touch();
    unawaited(flush());
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

  /// То же, что [allowedDevices], но сначала дожидается записи состояния доверия на диск; не записалось —
  /// сообщения получают только ваши устройства (так подключено к клиенту Matrix).
  Future<List<DeviceKeys>> allowedDevicesChecked(List<DeviceKeys> devices, String eventType, Map<String, dynamic> message) async {
    if (!await flush()) return devices.where((d) => d.userId == client.userID).toList();
    return allowedDevices(devices, eventType, message);
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
    // состояние доверия (запомненные ключи, запреты, отметки о замене) должно быть записано на диск
    if (!await flush()) {
      throw MatrixException.fromJson({'errcode': 'M_FORBIDDEN', 'error': 'Ласточка: состояние доверия не записано'});
    }
    if (room.encrypted && !client.encryptionEnabled && !_noEncryptionAllowed) {
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

  /// Сбои для тестов. В выпускаемой сборке (kReleaseMode — константа компилятора) ни один из этих
  /// переключателей не действует: проверки ниже вырезаются компилятором, путь «включить» отсутствует.
  @visibleForTesting
  bool debugAllowNoEncryption = false;
  @visibleForTesting
  bool debugFailRotation = false;
  @visibleForTesting
  bool debugFailStorage = false;
  bool _fail(bool flag) => !kReleaseMode && flag;
  bool get _noEncryptionAllowed => !kReleaseMode && debugAllowNoEncryption;
  bool get encryptionRequired => !_noEncryptionAllowed;

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

  /// Заменить исходящие сеансы в этих чатах. Сначала чаты помечаются как ждущие замены и это ЗАПИСЫВАЕТСЯ
  /// (с проверкой) — только потом начинается замена; отметка снимается с чата после подтверждённой замены
  /// и тоже только когда снятие записано.
  /// null — отметку записать не удалось: замена не начата (с [keepIfNotSaved] чаты остаются заблокированными
  /// в памяти до успешной записи), true — все сеансы заменены, false — часть ещё ждёт (повтор после синхронизации).
  Future<bool?> _rotateRooms(Iterable<String> roomIds, {bool keepIfNotSaved = false}) async {
    final ids = roomIds.toList();
    final add = ids.where((r) => !_rotatePending.contains(r)).toList();
    if (add.isNotEmpty) {
      _rotatePending.addAll(add);
      _touch();
      if (!await flush()) {
        if (!keepIfNotSaved) {
          _rotatePending.removeAll(add);
          _touch();
        }
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
      if (_fail(debugFailRotation)) throw StateError('замена сеанса: тестовый сбой');
      // отметка о замене (и всё прочее состояние) должна лежать на диске до начала замены
      if (!await flush()) throw StateError('отметка о замене не записана');
      if (enc == null || !client.encryptionEnabled) {
        // модуль шифрования не работает — подтвердить замену нечем: это не успех
        if (!_noEncryptionAllowed) throw StateError('модуль шифрования недоступен');
      } else {
        await enc.keyManager.clearOrUseOutboundGroupSession(roomId, wipe: true);
        // проверяем результат, а не только отсутствие ошибки
        if (enc.keyManager.getOutboundGroupSession(roomId)?.outboundGroupSession != null) {
          throw StateError('старый сеанс шифрования остался');
        }
      }
      // снять отметку — только если снятие записалось; иначе чат остаётся заблокированным (память = диск)
      if (_rotatePending.remove(roomId)) {
        _touch();
        if (!await flush()) {
          _rotatePending.add(roomId);
          _touch();
          return false;
        }
      }
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
    if (dirty) {
      _touch();
      await flush();
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
      // сначала новое состояние записывается (с проверкой), и только потом — уведомление: иначе после
      // перезапуска о том же входе сообщили бы снова, или наоборот — запись потерялась бы
      final oldSessions = Set.of(_mySessions), oldSeeded = _seeded, oldLogins = newLogins.value;
      var fresh = <String>[];
      if (!_seeded) {
        _mySessions = ids; // первый запуск — все текущие считаем своими
        _seeded = true;
      } else {
        fresh = ids.difference(_mySessions).where((id) => id != client.deviceID).toList();
        _mySessions.addAll(fresh);
        final logins = [...newLogins.value, ...fresh].where(ids.contains).toList();
        if (!listEquals(logins, newLogins.value)) newLogins.value = logins;
      }
      _touch();
      if (!await flush()) {
        // не записалось — откатываем и сообщим при следующей проверке (через минуту)
        _mySessions = oldSessions;
        _seeded = oldSeeded;
        newLogins.value = oldLogins;
        _touch();
        return;
      }
      for (final id in fresh) {
        final d = devices.firstWhere((x) => x.deviceId == id);
        onNewLogin?.call(d.displayName ?? id);
      }
    } catch (e, s) {
      Logs().w('[Ласточка] Проверка своих сеансов', e, s);
    } finally {
      _sessionsBusy = false;
    }
  }

  /// После выхода из аккаунта: список своих сеансов начнётся заново.
  Future<void> resetOwnDevices() async {
    _mySessions = {};
    _seeded = false;
    newLogins.value = [];
    _touch();
    await flush();
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
    // Принятие ключа и отметка «чаты с ним ждут замены сеанса» записываются ОДНОЙ записью (атомарно, с
    // проверкой обратным чтением): после любого сбоя или аварийного завершения на диске либо прежнее
    // состояние (ключ не принят, запрет), либо новое (ключ принят, чаты заблокированы до замены сеансов).
    final rooms = _roomsWith(userId);
    final before = _snapshot();
    _rotatePending.addAll(rooms);
    _pins[userId] = mk!.publicKey!;
    _pinVerified[userId] = mk.verified;
    _setChanged(Map.of(_changed)..remove(userId));
    _touch();
    if (!await flush()) {
      // не записалось — возвращаем память к прежнему состоянию (запрет остаётся)
      _load(before);
      _touch();
      return AcceptResult.refused;
    }
    // новые сеансы шифрования; чат разблокируется только после подтверждённой (и записанной) замены
    var ok = true;
    for (final r in rooms) {
      if (!await _rotateRoom(r)) ok = false;
    }
    return ok ? AcceptResult.done : AcceptResult.rotating;
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
    _touch();
    await flush();
  }

  /// Кто в этом чате сменил ключ личности.
  /// В чате есть собеседник со сменившимся ключом, которого вы ещё не приняли, — отправлять туда нельзя
  /// ни одним способом (ветка, пересылка, отложенные, повтор неотправленных).
  bool sendBlocked(Room room) {
    if (!room.encrypted) return false;
    if (!client.encryptionEnabled && !_noEncryptionAllowed) return true;
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
