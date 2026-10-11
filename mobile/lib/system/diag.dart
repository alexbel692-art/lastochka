// Отчёт для диагностики: версия, устройство, последние ошибки. Без переписки: адреса, имена,
// идентификаторы, ссылки и пути к файлам вырезаются, поэтому отчёт можно спокойно переслать.
import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:ui';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:matrix/matrix.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../main.dart';
import '../matrix_client.dart';
import 'updater.dart';

class Diag {
  static final List<String> _buf = [];

  static void add(String s) {
    final line = '${DateTime.now().toIso8601String().substring(0, 19)} $s';
    _buf.add(line);
    if (_buf.length > 200) _buf.removeRange(0, _buf.length - 200);
    _persist(line);
  }

  /// Ошибка, которую приложение «проглотило» (показало «не получилось»), — с местом и началом стека.
  static void err(String where, Object e, [StackTrace? st]) {
    final stack = st == null ? '' : '\n${st.toString().split('\n').where((l) => l.trim().isNotEmpty).take(6).join('\n')}';
    add('$where: $e$stack');
  }

  // ---------- журнал на диске: переживает перезапуск, хранится уже очищенным ----------
  static File? _log;
  static final List<String> _pending = [];
  static List<String> _prev = const [];
  static const _logMax = 256 * 1024;

  static void _persist(String line) {
    final clean = scrub(line).replaceAll('\n', '\n    ');
    final f = _log;
    if (f == null) {
      _pending.add(clean);
      return;
    }
    try {
      f.writeAsStringSync('$clean\n', mode: FileMode.append, flush: true);
    } catch (_) {}
  }

  static Future<void> _openLog(String dir) async {
    final f = File(p.join(dir, 'diag_log.txt'));
    try {
      if (await f.exists()) {
        var text = await f.readAsString();
        if (text.length > _logMax) {
          text = text.substring(text.length - _logMax ~/ 2);
          await f.writeAsString(text, flush: true);
        }
        _prev = text.trim().split('\n').reversed.take(80).toList().reversed.toList();
      }
      await f.writeAsString('=== запуск ${DateTime.now().toIso8601String().substring(0, 19)}, Ласточка $appVersion ===\n${_pending.map((l) => '$l\n').join()}',
          mode: FileMode.append, flush: true);
      _pending.clear();
      _log = f;
    } catch (_) {}
  }

  /// Итоги последнего звонка (тип соединения, потери, задержка) — для жалоб «не слышно» и «обрывается».
  static String? lastCall;

  // «Следы» важных шагов (звонок и т. п.) пишутся в файл сразу: если приложение зависнет и его
  // перезапустят, в следующем отчёте будет видно, на каком шаге это случилось.
  static File? _trail;

  static Future<void> initTrail() async {
    final dir = (await getApplicationSupportDirectory()).path;
    await _openLog(dir);
    // следы прошлого запуска: зависание (Android — со стеком, другие платформы — сторож ниже)
    // и падение системной части Android
    var hung = false;
    for (final (name, title) in [('anr_trace.txt', 'Зависание (прошлый запуск)'), ('hang.txt', 'Зависание (прошлый запуск)'), ('native_crash.txt', 'Падение системной части Android (прошлый запуск)')]) {
      try {
        final f = File(p.join(dir, name));
        if (await f.exists()) {
          final t = await f.readAsString();
          await f.delete();
          if (name != 'native_crash.txt') hung = true;
          add('$title:\n${t.length > 6000 ? t.substring(0, 6000) : t}');
        }
      } catch (_) {}
    }
    if (!Platform.isAndroid) _startWatchdog(dir);
    try {
      final f = File(p.join(dir, 'diag_trail.txt'));
      _trail = f;
      if (await f.exists()) {
        final lines = (await f.readAsString()).trim().split('\n');
        if (lines.isNotEmpty && lines.last.isNotEmpty && (hung || !lines.last.endsWith('— готово'))) {
          add('Прошлый запуск оборвался после шага: ${lines.last}');
          for (final l in lines.reversed.take(30).toList().reversed) {
            add('  след: $l');
          }
        }
      }
    } catch (_) {}
  }

  // ---------- сторож зависаний (iPhone, Mac, Windows) ----------
  // Отдельный поток раз в 2 с «стучится» в главный. Если тот молчит дольше 6 с — пишет файл hang.txt
  // с последними шагами; если приложение так и закроют, файл попадёт в следующий отчёт.
  static ReceivePort? _wdPort;

  static void _startWatchdog(String dir) {
    if (_wdPort != null) return;
    final port = ReceivePort();
    _wdPort = port;
    port.listen((m) {
      if (m is SendPort) {
        _wdReply = m;
      } else if (m == 'ping') {
        _wdReply?.send('pong');
      } else if (m is String && m.startsWith('recovered:')) {
        add('Интерфейс не отвечал ${m.substring(10)} с');
      }
    });
    Isolate.spawn(_watchdog, (port.sendPort, dir), debugName: 'watchdog').catchError((Object e) {
      add('Сторож зависаний не запустился: $e');
      return Isolate.current;
    });
  }

  static SendPort? _wdReply;

  static Future<void> _watchdog((SendPort, String) a) async {
    final (main, dir) = a;
    final inbox = ReceivePort();
    main.send(inbox.sendPort);
    final hang = File(p.join(dir, 'hang.txt'));
    var lastPong = DateTime.now();
    var lastTick = DateTime.now();
    DateTime? hungSince;
    inbox.listen((m) {
      if (m is SendPort) return;
      lastPong = DateTime.now();
      final h = hungSince;
      if (h != null) {
        hungSince = null;
        try {
          hang.deleteSync();
        } catch (_) {}
        main.send('recovered:${DateTime.now().difference(h).inSeconds}');
      }
    });
    Timer.periodic(const Duration(seconds: 2), (_) {
      final now = DateTime.now();
      // весь процесс стоял (свёрнуто, сон компьютера) — это не зависание
      if (now.difference(lastTick).inSeconds > 4) lastPong = now;
      lastTick = now;
      main.send('ping');
      if (hungSince == null && now.difference(lastPong).inSeconds >= 6) {
        hungSince = lastPong;
        var steps = '';
        try {
          final t = File(p.join(dir, 'diag_trail.txt'));
          if (t.existsSync()) steps = t.readAsLinesSync().reversed.take(15).toList().reversed.join('\n');
        } catch (_) {}
        try {
          hang.writeAsStringSync('интерфейс не отвечает с ${lastPong.toIso8601String().substring(11, 19)}\nпоследние шаги:\n$steps', flush: true);
        } catch (_) {}
      }
    });
  }

  /// Ошибки синхронизации с сервером (не чаще раза в минуту для одной и той же ошибки).
  static void watchClient(Client c) {
    String? last;
    var at = DateTime(2000);
    c.onSyncStatus.stream.listen((s) {
      if (s.status != SyncStatus.error) return;
      final e = '${s.error?.exception}';
      if (e == last && DateTime.now().difference(at).inSeconds < 60) return;
      last = e;
      at = DateTime.now();
      add('Синхронизация: $e');
    });
  }

  /// Записать шаг. [start] — начать новую цепочку (например, новый звонок).
  static void mark(String step, {bool start = false}) {
    final line = '${DateTime.now().toIso8601String().substring(11, 23)} $step';
    try {
      _trail?.writeAsStringSync('$line\n', mode: start ? FileMode.write : FileMode.append, flush: true);
    } catch (_) {}
  }

  /// Перехват ошибок приложения (сами ошибки по-прежнему обрабатываются как раньше).
  static void init() {
    final prev = FlutterError.onError;
    FlutterError.onError = (d) {
      add('Flutter: ${d.exceptionAsString()}\n${d.stack ?? ''}');
      prev?.call(d);
    };
    PlatformDispatcher.instance.onError = (e, st) {
      add('Dart: $e\n$st');
      return false;
    };
  }

  /// Скрыть всё, что может указать на людей, переписку или сервер.
  static String scrub(String s, {String? host, String? domain}) {
    try {
      s = Uri.decodeFull(s); // %40имя%3Aсервер в адресах запросов
    } catch (_) {}
    var r = s
        .replaceAll(RegExp(r'@[^\s:]+:[A-Za-z0-9.\-]+'), '@<пользователь>')
        .replaceAll(RegExp(r'![A-Za-z0-9]+:[A-Za-z0-9.\-]+'), '!<чат>')
        .replaceAll(RegExp(r'#[^\s:]+:[A-Za-z0-9.\-]+'), '#<чат>')
        .replaceAll(RegExp(r'\$[A-Za-z0-9_\-+/]{20,}'), r'$<событие>')
        .replaceAll(RegExp(r'mxc://\S+'), 'mxc://<файл>')
        .replaceAll(RegExp(r'![A-Za-z0-9_\-]{20,}'), '!<чат>')
        .replaceAll(RegExp(r'(https?|wss?)://\S+'), '<адрес>')
        .replaceAll(RegExp(r'[\w.+-]+@[\w-]+\.[\w.]+'), '<почта>')
        // имена серверов (но не файлы из трассировки: chat.dart, Foo.kt…)
        .replaceAllMapped(RegExp(r'\b(?:[a-z0-9-]+\.)+[a-z]{2,6}\b'),
            (m) => RegExp(r'\.(dart|kt|java|swift|mm|cc|cpp|h|so|dll|js|json|png|jpg|mp4)$').hasMatch(m[0]!) || RegExp(r'^(m|org\.matrix|im|io|ru\.lastochka)\.').hasMatch(m[0]!) ? m[0]! : '<сайт>')
        .replaceAll(RegExp(r'\b(?:[0-9a-fA-F]{1,4}:){3,7}[0-9a-fA-F]{1,4}\b|\b[0-9a-fA-F]{0,4}::[0-9a-fA-F:]+\b'), '<ip>')
        .replaceAll(RegExp(r'\b\d{1,3}(\.\d{1,3}){3}\b'), '<ip>')
        .replaceAll(RegExp(r'(syt|syt_|mat_|Bearer )\S+'), '<токен>')
        .replaceAllMapped(RegExp(r'(/Users/|/home/|\\Users\\)[^/\\\s]+'), (m) => '${m[1]}<имя>');
    for (final h in [host, domain]) {
      if (h != null && h.isNotEmpty) r = r.replaceAll(h, '<сервер>');
    }
    return r;
  }

  static Future<String> report() async {
    final enc = client.encryption;
    bool? backup, cached;
    try {
      backup = enc?.keyManager.enabled;
      cached = await enc?.keyManager.isCached();
    } catch (_) {}
    String? battery;
    if (Platform.isAndroid) {
      try {
        final ok = await const MethodChannel('lastochka/system').invokeMethod<bool>('isIgnoringBattery');
        battery = ok == true ? 'без ограничений' : 'ограничена системой (уведомления и звонки могут опаздывать)';
      } catch (_) {}
    }
    var beta = false;
    try {
      beta = (await SharedPreferences.getInstance()).getBool('update.beta') ?? false;
    } catch (_) {}
    final lines = <String>[
      'Ласточка $appVersion${beta ? ' (тестовые версии)' : ''}',
      'Система: ${Platform.operatingSystem} ${Platform.operatingSystemVersion}',
      'Устройство: ${deviceLabel()}',
      'Режим: ${kReleaseMode ? 'release' : 'debug'}',
      'Вход выполнен: ${client.isLogged() ? 'да' : 'нет'}',
      'Синхронизация: ${client.prevBatch == null ? 'ещё не было' : 'есть'}',
      'Подпись устройств: ${enc?.crossSigning.enabled == true ? 'включена' : 'нет'}',
      'Это устройство подтверждено: ${client.isUnknownSession ? 'нет' : 'да'}',
      'Резервная копия ключей: ${backup == true ? 'есть' : 'нет'}${cached == true ? ', подключена' : ''}',
      'Чатов: ${client.rooms.length}',
      if (battery != null) 'Работа в фоне: $battery',
      if (lastCall != null) 'Последний звонок: $lastCall',
      '',
      '— Ошибки приложения —',
      ..._buf,
      '',
      if (_prev.isNotEmpty) ...['— Прошлые запуски (последние строки) —', ..._prev, ''],
      '— Журнал Matrix (предупреждения и ошибки) —',
      for (final e in Logs().outputEvents.where((e) => e.level.index <= Level.warning.index).toList().reversed.take(80).toList().reversed)
        '${e.level.name}: ${e.title}${e.exception != null ? ' — ${e.exception}' : ''}',
    ];
    return scrub(lines.join('\n'), host: client.homeserver?.host, domain: client.userID?.domain);
  }
}
