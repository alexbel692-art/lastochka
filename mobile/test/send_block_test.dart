// Функциональные тесты: настоящий клиент Matrix (LastochkaClient) с настоящей базой и подменённым сервером.
// Проверяется, что при смене ключа собеседника НИ ОДНА отправка не доходит до сервера — какой бы метод
// модуля Matrix ни использовался, — в том числе когда ключ сменился, а проверка после синхронизации ещё
// не прошла (гонка), когда ключ пропал, когда проверка ключей сломалась (fail-closed); и что ключи
// шифрования не раздаются устройствам такого собеседника.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lastochka/main.dart' as app;
import 'package:lastochka/matrix_client.dart';
import 'package:lastochka/system/trust.dart';
import 'package:matrix/matrix.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const me = '@me:test', bob = '@bob:test', roomId = '!r:test', groupId = '!g:test';

/// Запросы, дошедшие до «сервера».
final requests = <String>[];
List<String> get sends => requests.where((r) => r.startsWith('PUT') && r.contains('/send/')).toList();
var _ev = 0;

Map<String, Object?> _state(String type, String key, Map<String, Object?> content, String sender) => {
      'type': type,
      'state_key': key,
      'content': content,
      'sender': sender,
      'event_id': '\$s${_ev++}',
      'origin_server_ts': 1,
    };

final syncJson = {
  'next_batch': 's1',
  'account_data': {
    'events': [
      {
        'type': 'm.direct',
        'content': {
          bob: [roomId],
        },
      },
    ],
  },
  'rooms': {
    'join': {
      roomId: {
        'summary': {'m.joined_member_count': 2, 'm.invited_member_count': 0},
        'state': {
          'events': [
            _state('m.room.create', '', {'creator': me}, me),
            _state('m.room.encryption', '', {'algorithm': 'm.megolm.v1.aes-sha2'}, me),
            _state('m.room.member', me, {'membership': 'join'}, me),
            _state('m.room.member', bob, {'membership': 'join'}, bob),
          ],
        },
        'timeline': {'events': [], 'limited': false},
      },
      // групповой защищённый чат с тем же собеседником
      groupId: {
        'summary': {'m.joined_member_count': 3, 'm.invited_member_count': 0},
        'state': {
          'events': [
            _state('m.room.create', '', {'creator': me}, me),
            _state('m.room.encryption', '', {'algorithm': 'm.megolm.v1.aes-sha2'}, me),
            _state('m.room.member', me, {'membership': 'join'}, me),
            _state('m.room.member', bob, {'membership': 'join'}, bob),
            _state('m.room.member', '@carol:test', {'membership': 'join'}, '@carol:test'),
          ],
        },
        'timeline': {'events': [], 'limited': false},
      },
    },
  },
};

List<DeviceKeys> get bobDevices => app.client.userDeviceKeys[bob]!.deviceKeys.values.toList();
List<DeviceKeys> get allDevices => [...app.client.userDeviceKeys[me]!.deviceKeys.values, ...bobDevices];
Map<String, dynamic> roomKey(String rid) => {'algorithm': 'm.megolm.v1.aes-sha2', 'room_id': rid, 'session_id': 's', 'session_key': 'k'};

/// Как модуль Matrix в защищённом чате: сначала показывает неотправленное событие (исходный тип),
/// потом вызывает sendMessage уже с типом m.room.encrypted и шифротекстом.
Future<void> sendEncryptedLike(String rid, String type, Map<String, Object?> content) async {
  final tx = 'tx${_ev++}';
  final update = SyncUpdate.fromJson({
    'next_batch': '',
    'rooms': {
      'join': {
        rid: {
          'timeline': {
            'events': [
              {
                'type': type,
                'content': content,
                'event_id': tx,
                'sender': me,
                'origin_server_ts': 1,
                'unsigned': {'transaction_id': tx},
              },
            ],
          },
        },
      },
    },
  });
  await app.client.database.transaction(() => app.client.handleSync(update));
  await app.client.sendMessage(rid, EventTypes.Encrypted, tx, {'algorithm': 'm.megolm.v1.aes-sha2', 'ciphertext': 'x'});
}

Future<bool> passes(Future<void> Function() send) async {
  requests.clear();
  try {
    await send();
  } catch (_) {}
  return sends.isNotEmpty;
}

Future<http.Response> _server(http.Request r) async {
  final path = r.url.path;
  requests.add('${r.method} $path');
  Object? body = {};
  if (path.contains('/versions')) {
    body = {
      'versions': ['v1.1', 'v1.11'],
    };
  } else if (path.endsWith('/filter')) {
    body = {'filter_id': 'f1'};
  } else if (path.contains('/sync')) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
    body = syncJson;
  } else if (r.method == 'PUT' && path.contains('/send/')) {
    body = {'event_id': '\$e${_ev++}'};
  } else if (path.contains('/keys/query')) {
    body = {'device_keys': {}, 'failures': {}};
  } else if (path.contains('/upload')) {
    body = {'content_uri': 'mxc://test/file'};
  } else if (path.contains('/media/config') || path.endsWith('/config')) {
    body = {'m.upload.size': 50000000};
  }
  return http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json'});
}

DeviceKeysList keysOf(String uid, String? master, {bool outdated = false}) {
  final c = app.client;
  final l = DeviceKeysList(uid, c)..outdated = outdated;
  if (master != null) {
    l.crossSigningKeys[master] = CrossSigningKey.fromJson({
      'user_id': uid,
      'usage': ['master'],
      'keys': {'ed25519:$master': master},
      'signatures': <String, Object?>{},
    }, c);
  }
  final dev = uid == me ? 'MYDEV' : 'BOBDEV';
  l.deviceKeys[dev] = DeviceKeys.fromJson({
    'user_id': uid,
    'device_id': dev,
    'algorithms': ['m.olm.v1.curve25519-aes-sha2', 'm.megolm.v1.aes-sha2'],
    'keys': {'curve25519:$dev': 'curve-$uid', 'ed25519:$dev': 'ed-$uid'},
    'signatures': <String, Object?>{},
  }, c);
  return l;
}

void setBobKey(String? master, {bool outdated = false}) => app.client.userDeviceKeys[bob] = keysOf(bob, master, outdated: outdated);

Room get room => app.client.getRoomById(roomId)!;

/// Все способы отправки модуля Matrix, которыми пользуется Ласточка (и прямой вызов sendMessage).
final attempts = <String, Future<Object?> Function()>{
  'текст': () => room.sendTextEvent('секрет'),
  'реакция': () => room.sendReaction('\$x', '👍'),
  'геопозиция': () => room.sendLocation('тут', 'geo:55.7,37.6'),
  'опрос': () => room.sendEvent({
        'org.matrix.msc3381.poll.start': {
          'question': {'org.matrix.msc1767.text': 'да?'},
          'answers': [],
        },
      }, type: 'org.matrix.msc3381.poll.start'),
  'голос в опросе': () => room.sendEvent({'org.matrix.msc3381.poll.response': {'answers': []}}, type: 'org.matrix.msc3381.poll.response'),
  'звонок': () => room.sendEvent({'call_id': 'c1', 'version': '1', 'lifetime': 60000}, type: 'm.call.invite'),
  'ответ на звонок': () => room.sendEvent({'call_id': 'c1', 'version': '1'}, type: 'm.call.answer'),
  'файл': () => room.sendFileEvent(MatrixFile(bytes: Uint8List.fromList([1, 2, 3]), name: 'a.txt')),
  'прямой sendMessage': () => app.client.sendMessage(roomId, 'm.room.message', 'tx${_ev++}', {'msgtype': 'm.text', 'body': 'x'}),
};

Future<void> expectAllBlocked(String why) async {
  for (final MapEntry(key: name, value: send) in attempts.entries) {
    requests.clear();
    try {
      await send().timeout(const Duration(seconds: 10));
    } on TimeoutException {
      fail('$why: «$name» зависла');
    } catch (_) {
      // отказ — это и ожидается
    }
    if (sends.isNotEmpty) fail('ERROR: $why: «$name» дошла до сервера: ${sends.join(', ')}');
  }
  expect(() => ensureCanSend(room), throwsA(isA<SendBlocked>()), reason: why);
}

Future<void> expectSent(String why) async {
  requests.clear();
  await room.sendTextEvent('привет').timeout(const Duration(seconds: 10));
  expect(sends, hasLength(1), reason: why);
}

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    Logs().level = Level.error; // меньше шума: отказы в отправке модуль Matrix пишет предупреждениями
    SharedPreferences.setMockInitialValues({});
    sqfliteFfiInit();
    final factory = createDatabaseFactoryFfi();
    final db = await MatrixSdkDatabase.init('trust_test', database: await factory.openDatabase(':memory:'));
    final c = LastochkaClient('trust_test', database: db, httpClient: MockClient(_server));
    app.client = c;
    await c.init(
      newToken: 'token',
      newHomeserver: Uri.parse('https://hs.test'),
      newUserID: me,
      newDeviceID: 'MYDEV',
      newDeviceName: 'test',
      waitForFirstSync: false,
    );
    await c.firstSyncReceived;
    await c.abortSync();
    expect(c.getRoomById(roomId)?.encrypted, isTrue, reason: 'тестовый чат должен быть защищённым');
    await Trust.instance.init();
    c.userDeviceKeys[me] = keysOf(me, 'MY-MASTER');
    setBobKey('K1');
    await Trust.instance.checkNow(); // первая встреча — ключ K1 запомнен
  });

  test('ключ переслало неподтверждённое устройство самого отправителя — предупреждение', () {
    final w = Trust.instance.debugJudgeSession(bob, ['curve-$bob'], 'curve-$bob', {'ed25519': 'ed-$bob'});
    expect(w, contains('неподтверждённое устройство отправителя'));
  });

  test('SEC-01: отправка в неизвестный чат не проходит (fail-closed)', () async {
    requests.clear();
    await expectLater(
        app.client.sendMessage('!unknown:test', 'm.room.message', 'u${_ev++}', {'msgtype': 'm.text', 'body': 'x'}), throwsA(isA<MatrixException>()));
    expect(sends, isEmpty);
  });

  test('обычная отправка проходит', () async {
    expect(Trust.instance.changedNow, isEmpty);
    await expectSent('ключ не менялся');
  });

  test('гонка: ключ сменился, проверка после синхронизации ещё не прошла — всё равно ничего не уходит', () async {
    setBobKey('K2'); // checkNow не вызываем — как будто отправка опередила обработку синхронизации
    await expectAllBlocked('ключ сменился');
    expect(Trust.instance.changedNow.containsKey(bob), isTrue);
  });

  test('ключи шифрования не раздаются устройствам собеседника со сменившимся ключом', () {
    expect(Trust.instance.allowedDevices(allDevices, EventTypes.RoomKey, roomKey(roomId)).map((d) => d.userId), [me]);
    expect(Trust.instance.allowedDevices(allDevices, EventTypes.RoomKey, roomKey(groupId)).map((d) => d.userId), [me]);
    expect(Trust.instance.allowedDevices(allDevices, 'm.forwarded_room_key', roomKey(roomId)).map((d) => d.userId), [me]);
  });

  test('SEC-07: ключ пропал — принять нельзя, отправка остаётся запрещённой', () async {
    setBobKey(null);
    expect(await Trust.instance.acceptChange(bob), AcceptResult.refused);
    expect(await Trust.instance.acceptChange(bob, shownKey: 'K2'), AcceptResult.refused);
    await expectAllBlocked('ключ пропал');
  });

  test('ключ ещё не загружен (список устарел) — принять нельзя', () async {
    setBobKey('K2', outdated: true);
    expect(await Trust.instance.acceptChange(bob, shownKey: 'K2'), AcceptResult.refused);
    await expectAllBlocked('ключ не загружен');
  });

  test('подмена ключа после показа — «Понятно» не принимает чужой ключ', () async {
    setBobKey('KEVE');
    expect(await Trust.instance.acceptChange(bob, shownKey: 'K2'), AcceptResult.refused);
    await expectAllBlocked('показан другой ключ');
  });

  test('во время сравнения эмодзи проходят ТОЛЬКО события проверки и только в личном чате', () async {
    await Trust.instance.whileVerifying(bob, () async {
      // события проверки в личном чате — проходят (и открытым, и зашифрованным путём)
      expect(await passes(() => app.client.sendMessage(roomId, 'm.room.message', 'v${_ev++}', {'msgtype': 'm.key.verification.request'})), isTrue);
      expect(await passes(() => app.client.sendMessage(roomId, 'm.key.verification.start', 'v${_ev++}', {})), isTrue);
      expect(await passes(() => sendEncryptedLike(roomId, 'm.key.verification.mac', {})), isTrue);
      expect(await passes(() => sendEncryptedLike(roomId, 'm.room.message', {'msgtype': 'm.key.verification.request'})), isTrue);

      // SEC-01: обычные сообщения в тот же личный чат в это время — запрещены
      expect(await passes(() => app.client.sendMessage(roomId, 'm.room.message', 'm${_ev++}', {'msgtype': 'm.text', 'body': 'секрет'})), isFalse);
      expect(await passes(() => sendEncryptedLike(roomId, 'm.room.message', {'msgtype': 'm.text', 'body': 'секрет'})), isFalse);
      expect(await passes(() => sendEncryptedLike(roomId, 'm.reaction', {})), isFalse);
      // зашифрованное событие неизвестного происхождения — тоже нет
      expect(await passes(() => app.client.sendMessage(roomId, EventTypes.Encrypted, 'unknown${_ev++}', {'ciphertext': 'x'})), isFalse);
      // события проверки в групповой чат — нет (исключение только для личного)
      expect(await passes(() => app.client.sendMessage(groupId, 'm.key.verification.start', 'v${_ev++}', {})), isFalse);
      await expectAllBlocked('идёт сравнение эмодзи, обычные отправки');

      // SEC-02: ключ сеанса — только личного чата проверки; ключи других чатов и пересылаемые — нет
      expect(Trust.instance.allowedDevices(bobDevices, EventTypes.RoomKey, roomKey(roomId)), hasLength(1));
      expect(Trust.instance.allowedDevices(bobDevices, EventTypes.RoomKey, roomKey(groupId)), isEmpty);
      expect(Trust.instance.allowedDevices(bobDevices, 'm.forwarded_room_key', roomKey(roomId)), isEmpty);
      expect(Trust.instance.allowedDevices(bobDevices, 'm.call.invite', {}), isEmpty);
      // события проверки идут в личном чате; личным сообщениям устройствам исключение не нужно
      expect(Trust.instance.allowedDevices(bobDevices, 'm.key.verification.start', {}), isEmpty);
      // интерфейс по-прежнему не даёт писать
      expect(() => ensureCanSend(room), throwsA(isA<SendBlocked>()));
    });
    // проверка закончилась без подтверждения — снова полный запрет
    expect(await passes(() => app.client.sendMessage(roomId, 'm.key.verification.start', 'v${_ev++}', {})), isFalse);
    expect(Trust.instance.allowedDevices(bobDevices, EventTypes.RoomKey, roomKey(roomId)), isEmpty);
    await expectAllBlocked('проверка эмодзи закончилась без подтверждения');
  });

  test('сбой проверки ключей — запрет (fail-closed), ключи только своим устройствам', () async {
    Trust.instance.debugFailChecks = true;
    try {
      await expectAllBlocked('проверка ключей не удалась');
      expect(Trust.instance.checkFailed, isTrue);
      final all = [...app.client.userDeviceKeys[me]!.deviceKeys.values, ...app.client.userDeviceKeys[bob]!.deviceKeys.values];
      expect(Trust.instance.allowedDevices(all, EventTypes.RoomKey, roomKey(groupId)).map((d) => d.userId), [me]);
    } finally {
      Trust.instance.debugFailChecks = false;
    }
  });

  test('не удалось сохранить состояние — ключ НЕ принят, запрет остаётся', () async {
    Trust.instance.debugFailStorage = true;
    try {
      expect(await Trust.instance.acceptChange(bob, shownKey: Trust.instance.currentKey(bob)), AcceptResult.refused);
    } finally {
      Trust.instance.debugFailStorage = false;
    }
    expect(Trust.instance.changedNow.containsKey(bob), isTrue);
    expect(Trust.instance.rotationPending, isEmpty, reason: 'ничего не начато');
    await expectAllBlocked('состояние не сохранилось');
  });

  test('ключ принят, но замена сеансов не удалась — чаты заблокированы, отметка на диске, после восстановления — работает', () async {
    final shown = Trust.instance.currentKey(bob);
    expect(shown, 'KEVE');
    Trust.instance.debugFailRotation = true;
    try {
      expect(await Trust.instance.acceptChange(bob, shownKey: shown), AcceptResult.rotating);
    } finally {
      Trust.instance.debugFailRotation = false;
    }
    expect(Trust.instance.changedNow, isEmpty, reason: 'ключ принят');
    expect(Trust.instance.rotationPending, containsAll([roomId, groupId]));
    // отметка уже на диске — после аварийного перезапуска чаты останутся заблокированными
    final saved = (await SharedPreferences.getInstance()).getStringList('trust.rotatePending') ?? [];
    expect(saved, containsAll([roomId, groupId]));
    await expectAllBlocked('сеанс шифрования ещё не заменён');
    expect(Trust.instance.allowedDevices(allDevices, EventTypes.RoomKey, roomKey(roomId)).map((d) => d.userId), [me]);
    // шифрование снова работает — замена повторяется при синхронизации
    await Trust.instance.checkNow();
    expect(Trust.instance.rotationPending, isEmpty);
    expect((await SharedPreferences.getInstance()).getStringList('trust.rotatePending') ?? [], isEmpty);
    await expectSent('ключ принят, сеансы заменены');
  });

  test('ключи знакомого собеседника не загружены — отправка ждёт, отсутствие данных не разрешение', () async {
    app.client.userDeviceKeys[bob] = keysOf(bob, 'KEVE', outdated: true); // сервер «не отдаёт» новый список
    requests.clear();
    try {
      await room.sendTextEvent('пока ключи неизвестны').timeout(const Duration(seconds: 10));
    } catch (_) {}
    expect(sends, isEmpty);
    expect(requests.any((r) => r.contains('/keys/query')), isTrue, reason: 'попытались догрузить ключи');
    setBobKey('KEVE');
    await expectSent('ключи загружены');
  });

  test('после принятия новая смена снова запрещает отправку', () async {
    setBobKey('K3');
    await expectAllBlocked('ещё одна смена ключа');
  });
}
