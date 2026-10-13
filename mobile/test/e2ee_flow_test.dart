// Сквозной тест с НАСТОЯЩИМ шифрованием (vodozemac) и настоящим потоком модуля Matrix SDK 11:
// два клиента — «я» (LastochkaClient + защита Ласточки) и собеседник Боб (обычный клиент Matrix) —
// общаются через маленький тестовый сервер Matrix в памяти. Проверяется:
//  • обычная переписка шифруется и расшифровывается у Боба;
//  • Боб сменил ключ личности (сервер сообщает об этом в синхронизации, как настоящий) — мои сообщения
//    к нему не уходят, ключи сеансов шифрования его устройству не раздаются;
//  • полное сравнение эмодзи (запрос → готовность → SAS → MAC → готово) в зашифрованном личном чате
//    проходит, а обычное сообщение, отправленное В ЭТО ЖЕ ВРЕМЯ, и сообщение в групповой чат — нет;
//    ключ группового чата Бобу не уходит;
//  • после подтверждения переписка снова работает.
// Нужна собранная библиотека vodozemac (tool/build_vodozemac_test_lib.sh); в CI тест обязателен.
import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lastochka/main.dart' as app;
import 'package:lastochka/matrix_client.dart';
import 'package:lastochka/system/trust.dart';
import 'package:matrix/encryption/utils/key_verification.dart';
import 'package:matrix/matrix.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:vodozemac/vodozemac.dart' as vod;

const me = '@me:test', bob = '@bob:test', dm = '!dm:test', group = '!group:test';
const myDev = 'MYDEV', bobDev = 'BOBDEV';

String canon(Object? v) => jsonEncode(_sorted(v));
Object? _sorted(Object? v) {
  if (v is Map) {
    final m = SplayTreeMap<String, Object?>();
    for (final e in v.entries) {
      m[e.key as String] = _sorted(e.value);
    }
    return m;
  }
  if (v is List) return v.map(_sorted).toList();
  return v;
}

Map<String, Object?> _unsignedCopy(Map<String, Object?> j) => Map.of(j)
  ..remove('signatures')
  ..remove('unsigned');

/// Маленький сервер Matrix в памяти: комнаты, синхронизация, ключи, личные сообщения устройствам.
class TestServer {
  final tokens = {'tok-me': me, 'tok-bob': bob};
  final devOf = {me: myDev, bob: bobDev};
  final log = <Map<String, Object?>>[]; // события комнат по порядку
  final toDevice = <String, List<Map<String, Object?>>>{me: [], bob: []};
  final deviceKeys = <String, Map<String, Object?>>{};
  final otks = <String, Map<String, Object?>>{}; // userId → {keyId: key}
  final fallback = <String, Map<String, Object?>>{};
  final listChanged = <String, Set<String>>{me: {}, bob: {}};
  final initialDone = <String>{};
  // кросс-подпись Боба (её «делает» сам тест)
  late vod.PkSigning bobMaster, bobSsk;
  /// Что дошло до сервера: (кто, путь)
  final requests = <(String, String)>[];
  final roomSendsBy = <String, List<(String room, String type)>>{me: [], bob: []};
  var _n = 0;

  final rooms = {
    dm: [me, bob],
    group: [me, bob, '@carol:test'],
  };

  TestServer() {
    newBobIdentity(notify: false);
  }

  void newBobIdentity({bool notify = true}) {
    bobMaster = vod.PkSigning();
    bobSsk = vod.PkSigning();
    if (notify) {
      listChanged[me]!.add(bob);
      listChanged[bob]!.add(bob);
    }
  }

  Map<String, Object?> _state(String rid, String type, String key, Map<String, Object?> content, String sender) => {
        'type': type,
        'state_key': key,
        'content': content,
        'sender': sender,
        'event_id': '\$st${_n++}',
        'origin_server_ts': 1,
        'room_id': rid,
      };

  List<Map<String, Object?>> _roomState(String rid) => [
        _state(rid, 'm.room.create', '', {'creator': me}, me),
        _state(rid, 'm.room.encryption', '', {'algorithm': 'm.megolm.v1.aes-sha2'}, me),
        for (final u in rooms[rid]!) _state(rid, 'm.room.member', u, {'membership': 'join'}, u),
      ];

  Map<String, Object?> _masterJson() {
    final pub = bobMaster.publicKey.toBase64();
    return {
      'user_id': bob,
      'usage': ['master'],
      'keys': {'ed25519:$pub': pub},
    };
  }

  Map<String, Object?> _sskJson() {
    final pub = bobSsk.publicKey.toBase64();
    final j = <String, Object?>{
      'user_id': bob,
      'usage': ['self_signing'],
      'keys': {'ed25519:$pub': pub},
    };
    j['signatures'] = {
      bob: {'ed25519:${bobMaster.publicKey.toBase64()}': bobMaster.sign(canon(j)).toBase64()},
    };
    return j;
  }

  Map<String, Object?>? _deviceJson(String user) {
    final d = deviceKeys[user];
    if (d == null) return null;
    if (user != bob) return d;
    // устройство Боба подписано его текущим ключом самоподписи
    final j = Map<String, Object?>.of(d);
    final sigs = <String, Object?>{...(j['signatures'] as Map? ?? {}).cast<String, Object?>()};
    final mine = <String, Object?>{...(sigs[bob] as Map? ?? {}).cast<String, Object?>()};
    mine['ed25519:${bobSsk.publicKey.toBase64()}'] = bobSsk.sign(canon(_unsignedCopy(d))).toBase64();
    sigs[bob] = mine;
    j['signatures'] = sigs;
    return j;
  }

  Future<http.Response> handle(http.Request r) async {
    final user = tokens[(r.headers['authorization'] ?? '').replaceFirst('Bearer ', '')] ?? '?';
    final path = r.url.path;
    requests.add((user, '${r.method} $path'));
    final body = r.body.isEmpty ? <String, Object?>{} : (jsonDecode(r.body) as Map).cast<String, Object?>();
    Object? res = <String, Object?>{};
    var code = 200;

    if (path.contains('/versions')) {
      res = {
        'versions': ['v1.1', 'v1.11'],
      };
    } else if (path.endsWith('/filter')) {
      res = {'filter_id': 'f'};
    } else if (path.contains('/sync')) {
      res = await _sync(user, r.url.queryParameters['since']);
    } else if (r.method == 'PUT' && path.contains('/send/')) {
      final parts = path.split('/');
      final i = parts.indexOf('send');
      final rid = Uri.decodeComponent(parts[i - 1]);
      final type = Uri.decodeComponent(parts[i + 1]);
      final txn = Uri.decodeComponent(parts[i + 2]);
      final id = '\$ev${_n++}';
      log.add({
        'type': type,
        'content': body,
        'sender': user,
        'event_id': id,
        'origin_server_ts': DateTime.now().millisecondsSinceEpoch,
        'room_id': rid,
        'unsigned': {'transaction_id': txn},
      });
      roomSendsBy[user]!.add((rid, type));
      res = {'event_id': id};
    } else if (r.method == 'PUT' && path.contains('/sendToDevice/')) {
      final parts = path.split('/');
      final type = Uri.decodeComponent(parts[parts.indexOf('sendToDevice') + 1]);
      final msgs = (body['messages'] as Map).cast<String, Object?>();
      for (final MapEntry(key: target, value: devs) in msgs.entries) {
        for (final content in (devs as Map).values) {
          toDevice[target]?.add({'type': type, 'sender': user, 'content': content});
        }
      }
    } else if (path.endsWith('/keys/upload')) {
      final dk = body['device_keys'];
      if (dk is Map) deviceKeys[user] = dk.cast<String, Object?>();
      final ot = body['one_time_keys'];
      if (ot is Map) (otks[user] ??= {}).addAll(ot.cast<String, Object?>());
      final fb = body['fallback_keys'] ?? body['org.matrix.msc2732.fallback_keys'];
      if (fb is Map && fb.isNotEmpty) fallback[user] = fb.cast<String, Object?>();
      res = {
        'one_time_key_counts': {'signed_curve25519': otks[user]?.length ?? 0},
      };
    } else if (path.endsWith('/keys/query')) {
      final want = (body['device_keys'] as Map? ?? {}).keys.cast<String>();
      res = {
        'device_keys': {
          for (final u in want)
            u: {if (_deviceJson(u) != null) devOf[u]!: _deviceJson(u)},
        },
        'master_keys': {if (want.contains(bob)) bob: _masterJson()},
        'self_signing_keys': {if (want.contains(bob)) bob: _sskJson()},
        'user_signing_keys': {},
        'failures': {},
      };
    } else if (path.endsWith('/keys/claim')) {
      final want = (body['one_time_keys'] as Map).cast<String, Object?>();
      final out = <String, Object?>{};
      for (final u in want.keys) {
        final pool = otks[u];
        Map<String, Object?>? key;
        if (pool != null && pool.isNotEmpty) {
          final k = pool.keys.first;
          key = {k: pool.remove(k)};
        } else if (fallback[u] != null) {
          key = fallback[u];
        }
        if (key != null) out[u] = {devOf[u]!: key};
      }
      res = {'one_time_keys': out, 'failures': {}};
    } else if (path.contains('/room_keys/')) {
      code = 404;
      res = {'errcode': 'M_NOT_FOUND', 'error': 'no backup'};
    } else if (path.endsWith('/members')) {
      final rid = Uri.decodeComponent(path.split('/rooms/').last.split('/').first);
      res = {
        'chunk': _roomState(rid).where((e) => e['type'] == 'm.room.member').toList(),
      };
    }
    return http.Response(jsonEncode(res), code, headers: {'content-type': 'application/json'});
  }

  Future<Map<String, Object?>> _sync(String user, String? since) async {
    final from = int.tryParse(since ?? '') ?? 0;
    final initial = !initialDone.contains(user);
    // «длинный опрос», но короткий: тесту не нужно ждать по 30 секунд
    for (var i = 0; i < 10; i++) {
      if (initial || log.length > from || toDevice[user]!.isNotEmpty || listChanged[user]!.isNotEmpty) break;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    initialDone.add(user);
    final events = log.sublist(from.clamp(0, log.length));
    final join = <String, Object?>{};
    for (final rid in rooms.keys) {
      if (!rooms[rid]!.contains(user)) continue;
      final evs = events.where((e) => e['room_id'] == rid).map((e) {
        final c = Map<String, Object?>.of(e);
        if (e['sender'] != user) c.remove('unsigned');
        return c;
      }).toList();
      if (!initial && evs.isEmpty) continue;
      join[rid] = {
        'summary': {'m.joined_member_count': rooms[rid]!.length, 'm.invited_member_count': 0},
        'state': {'events': initial ? _roomState(rid) : []},
        'timeline': {'events': evs, 'limited': false},
      };
    }
    final td = List<Map<String, Object?>>.of(toDevice[user]!);
    toDevice[user]!.clear();
    final changed = listChanged[user]!.toList();
    listChanged[user]!.clear();
    return {
      'next_batch': '${log.length}',
      if (initial)
        'account_data': {
          'events': [
            {
              'type': 'm.direct',
              'content': {
                (user == me ? bob : me): [dm],
              },
            },
          ],
        },
      'rooms': {'join': join},
      'to_device': {'events': td},
      'device_lists': {'changed': changed, 'left': []},
      'device_one_time_keys_count': {'signed_curve25519': otks[user]?.length ?? 0},
    };
  }
}

Future<void> waitFor(bool Function() ok, String what, {Duration timeout = const Duration(seconds: 30)}) async {
  final end = DateTime.now().add(timeout);
  while (!ok()) {
    if (DateTime.now().isAfter(end)) fail('не дождались: $what');
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

Future<DatabaseApi> memDb(String name) async =>
    MatrixSdkDatabase.init(name, database: await createDatabaseFactoryFfi().openDatabase(':memory:'));

void main() {
  final lib = Platform.environment['VODOZEMAC_LIB'] ?? '';
  final required = Platform.environment['REQUIRE_E2EE_TEST'] == '1';
  if (lib.isEmpty && !required) {
    test('сквозной тест шифрования (нужна библиотека vodozemac)', () {}, skip: 'VODOZEMAC_LIB не задан');
    return;
  }

  late TestServer server;
  late LastochkaClient my;
  late Client bobC;
  // расшифрованные Бобом сообщения и полученные им ключи сеансов (из каких чатов)
  final bobSaw = <String>[];
  final bobGotKeysFor = <String>[];

  Room myRoom(String id) => my.getRoomById(id)!;
  int mySends(String rid) => server.roomSendsBy[me]!.where((s) => s.$1 == rid).length;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    Logs().level = Level.error;
    expect(lib, isNotEmpty, reason: 'в CI библиотека vodozemac обязательна (REQUIRE_E2EE_TEST=1)');
    await vod.init(libraryPath: lib.endsWith('/') ? lib : '$lib/');
    SharedPreferences.setMockInitialValues({});
    sqfliteFfiInit();
    server = TestServer();

    bobC = Client('bob', database: await memDb('bob'), httpClient: MockClient(server.handle),
        verificationMethods: {KeyVerificationMethod.emoji, KeyVerificationMethod.numbers});
    await bobC.init(
        newToken: 'tok-bob', newHomeserver: Uri.parse('https://hs.test'), newUserID: bob, newDeviceID: bobDev, newDeviceName: 'bob');
    bobC.onTimelineEvent.stream.listen((e) {
      if (e.type == EventTypes.Message && e.messageType == MessageTypes.Text) bobSaw.add(e.body);
    });
    bobC.onToDeviceEvent.stream.listen((e) {
      if (e.type == EventTypes.RoomKey) bobGotKeysFor.add(e.content['room_id'] as String? ?? '?');
    });

    my = LastochkaClient('me', database: await memDb('me'), httpClient: MockClient(server.handle),
        verificationMethods: {KeyVerificationMethod.emoji, KeyVerificationMethod.numbers});
    app.client = my;
    await my.init(newToken: 'tok-me', newHomeserver: Uri.parse('https://hs.test'), newUserID: me, newDeviceID: myDev, newDeviceName: 'me');
    expect(my.encryptionEnabled, isTrue, reason: 'шифрование должно работать по-настоящему');
    await Trust.instance.init();
    await my.updateUserDeviceKeys(additionalUsers: {bob});
    await waitFor(() => my.userDeviceKeys[bob]?.masterKey != null, 'ключи Боба');
    await Trust.instance.checkNow();
    expect(Trust.instance.changedNow, isEmpty);
  });

  tearDownAll(() async {
    await my.dispose(closeDatabase: true);
    await bobC.dispose(closeDatabase: true);
  });

  test('обычная зашифрованная переписка: Боб получает ключ и расшифровывает', () async {
    await myRoom(dm).sendTextEvent('привет, Боб');
    await waitFor(() => bobSaw.contains('привет, Боб'), 'Боб расшифровал сообщение');
    expect(server.roomSendsBy[me]!.last.$2, EventTypes.Encrypted);
    expect(bobGotKeysFor, contains(dm));
  });

  test('Боб сменил ключ личности — сообщения ему не уходят, ключи сеансов не раздаются', () async {
    server.newBobIdentity(); // сервер сообщит об этом в следующей синхронизации, как настоящий
    final oldMaster = my.userDeviceKeys[bob]!.masterKey!.publicKey;
    await waitFor(() => my.userDeviceKeys[bob]?.masterKey?.publicKey != oldMaster, 'новый ключ Боба получен через синхронизацию');
    expect(Trust.instance.changedNow.containsKey(bob), isTrue, reason: 'смена замечена сразу после загрузки ключей');

    final dmBefore = mySends(dm), groupBefore = mySends(group), keysBefore = bobGotKeysFor.length;
    for (final rid in [dm, group]) {
      try {
        await myRoom(rid).sendTextEvent('не должно уйти');
      } catch (_) {}
    }
    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(mySends(dm), dmBefore);
    expect(mySends(group), groupBefore);
    expect(bobGotKeysFor.length, keysBefore, reason: 'новые ключи сеансов Бобу не раздаются');
    expect(bobSaw, isNot(contains('не должно уйти')));
  });

  test('сравнение эмодзи проходит целиком; обычные сообщения в это время не уходят; ключ группы — тоже', () async {
    // Боб после сброса заново настроил свою подпись (как сделает любой клиент): его новый ключ личности
    // подтверждён на его стороне — тогда он включает его в сверку, и мы подтверждаем именно ключ личности
    final newMaster = server.bobMaster.publicKey.toBase64();
    await waitFor(() => bobC.userDeviceKeys[bob]?.masterKey?.publicKey == newMaster, 'Боб видит свой новый ключ');
    await bobC.userDeviceKeys[bob]!.masterKey!.setVerified(true, false);

    final groupBefore = mySends(group);
    final verified = Completer<void>();
    // Боб принимает запрос и подтверждает эмодзи
    final bobSub = bobC.onKeyVerificationRequest.stream.listen((req) async {
      req.onUpdate = () async {
        if (req.state == KeyVerificationState.askSas) await req.acceptSas();
      };
      await req.acceptVerification();
    });

    await Trust.instance.whileVerifying(bob, () async {
      final req = KeyVerification(encryption: my.encryption!, room: myRoom(dm), userId: bob);
      req.onUpdate = () async {
        if (req.state == KeyVerificationState.askSas) await req.acceptSas();
        if (req.state == KeyVerificationState.done && !verified.isCompleted) verified.complete();
        if (req.state == KeyVerificationState.error && !verified.isCompleted) verified.completeError('проверка: ошибка ${req.canceledCode} ${req.canceledReason}');
      };
      await req.start();

      // В ЭТО ЖЕ ВРЕМЯ: обычное сообщение в личный чат и сообщение в групповой чат
      for (final rid in [dm, group]) {
        try {
          await myRoom(rid).sendTextEvent('секрет во время проверки');
        } catch (_) {}
      }
      await verified.future.timeout(const Duration(seconds: 60));
    });
    await bobSub.cancel();
    await Future<void>.delayed(const Duration(milliseconds: 500));

    expect(bobSaw, isNot(contains('секрет во время проверки')), reason: 'обычное сообщение во время проверки не ушло');
    expect(mySends(group), groupBefore, reason: 'в групповой чат во время проверки ничего не ушло');
    expect(bobGotKeysFor, isNot(contains(group)), reason: 'ключ группового чата Боб не получил');
    expect(Trust.instance.userVerified(bob), isTrue, reason: 'Боб подтверждён сравнением эмодзи');
  });

  test('после подтверждения: принимаем подтверждённый ключ — переписка снова идёт и расшифровывается', () async {
    expect(await Trust.instance.acceptChange(bob, shownKey: Trust.instance.currentKey(bob)), isTrue);
    await myRoom(dm).sendTextEvent('снова пишем');
    await waitFor(() => bobSaw.contains('снова пишем'), 'Боб расшифровал сообщение после подтверждения');
  });
}
