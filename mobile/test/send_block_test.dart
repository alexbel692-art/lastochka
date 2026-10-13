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

const me = '@me:test', bob = '@bob:test', roomId = '!r:test';

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
    },
  },
};

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
    expect(sends, isEmpty, reason: '$why: «$name» дошла до сервера');
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
    final all = [...app.client.userDeviceKeys[me]!.deviceKeys.values, ...app.client.userDeviceKeys[bob]!.deviceKeys.values];
    final allowed = Trust.instance.allowedDevices(all);
    expect(allowed.map((d) => d.userId), [me]);
  });

  test('SEC-07: ключ пропал — принять нельзя, отправка остаётся запрещённой', () async {
    setBobKey(null);
    expect(await Trust.instance.acceptChange(bob), isFalse);
    expect(await Trust.instance.acceptChange(bob, shownKey: 'K2'), isFalse);
    await expectAllBlocked('ключ пропал');
  });

  test('ключ ещё не загружен (список устарел) — принять нельзя', () async {
    setBobKey('K2', outdated: true);
    expect(await Trust.instance.acceptChange(bob, shownKey: 'K2'), isFalse);
    await expectAllBlocked('ключ не загружен');
  });

  test('подмена ключа после показа — «Понятно» не принимает чужой ключ', () async {
    setBobKey('KEVE');
    expect(await Trust.instance.acceptChange(bob, shownKey: 'K2'), isFalse);
    await expectAllBlocked('показан другой ключ');
  });

  test('во время сравнения эмодзи в личном чате проходят сообщения проверки, после — снова запрет', () async {
    await Trust.instance.whileVerifying(bob, () async {
      requests.clear();
      await app.client.sendMessage(roomId, 'm.room.message', 'v${_ev++}', {'msgtype': 'm.key.verification.request'});
      expect(sends, hasLength(1));
      // интерфейс по-прежнему не даёт писать
      expect(() => ensureCanSend(room), throwsA(isA<SendBlocked>()));
      // ключи получает и собеседник — иначе он не расшифрует запрос проверки
      expect(Trust.instance.allowedDevices(app.client.userDeviceKeys[bob]!.deviceKeys.values.toList()), hasLength(1));
    });
    await expectAllBlocked('проверка эмодзи закончилась без подтверждения');
  });

  test('сбой проверки ключей — запрет (fail-closed), ключи только своим устройствам', () async {
    Trust.instance.debugFailChecks = true;
    try {
      await expectAllBlocked('проверка ключей не удалась');
      expect(Trust.instance.checkFailed, isTrue);
      final all = [...app.client.userDeviceKeys[me]!.deviceKeys.values, ...app.client.userDeviceKeys[bob]!.deviceKeys.values];
      expect(Trust.instance.allowedDevices(all).map((d) => d.userId), [me]);
    } finally {
      Trust.instance.debugFailChecks = false;
    }
  });

  test('принят именно показанный ключ — отправка снова работает', () async {
    final shown = Trust.instance.currentKey(bob);
    expect(shown, 'KEVE');
    expect(await Trust.instance.acceptChange(bob, shownKey: shown), isTrue);
    expect(Trust.instance.changedNow, isEmpty);
    await expectSent('ключ принят');
  });

  test('после принятия новая смена снова запрещает отправку', () async {
    setBobKey('K3');
    await expectAllBlocked('ещё одна смена ключа');
  });
}
