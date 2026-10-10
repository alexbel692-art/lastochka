// Отчёт для диагностики: версия, устройство, последние ошибки. Без переписки: адреса, имена,
// идентификаторы, ссылки и пути к файлам вырезаются, поэтому отчёт можно спокойно переслать.
import 'dart:io';
import 'dart:ui';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'package:flutter/foundation.dart';
import 'package:matrix/matrix.dart';

import '../main.dart';
import '../matrix_client.dart';
import 'updater.dart';

class Diag {
  static final List<String> _buf = [];

  static void add(String s) {
    _buf.add('${DateTime.now().toIso8601String().substring(0, 19)} $s');
    if (_buf.length > 200) _buf.removeRange(0, _buf.length - 200);
  }

  // «Следы» важных шагов (звонок и т. п.) пишутся в файл сразу: если приложение зависнет и его
  // перезапустят, в следующем отчёте будет видно, на каком шаге это случилось.
  static File? _trail;

  static Future<void> initTrail() async {
    try {
      final f = File(p.join((await getApplicationSupportDirectory()).path, 'diag_trail.txt'));
      _trail = f;
      if (await f.exists()) {
        final lines = (await f.readAsString()).trim().split('\n');
        if (lines.isNotEmpty && lines.last.isNotEmpty && !lines.last.endsWith('— готово')) {
          add('Прошлый запуск оборвался после шага: ${lines.last}');
          for (final l in lines.reversed.take(12).toList().reversed) {
            add('  след: $l');
          }
        }
      }
    } catch (_) {}
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
            (m) => RegExp(r'\.(dart|kt|java|swift|mm|cc|cpp|h|so|dll|js|json|png|jpg|mp4)$').hasMatch(m[0]!) ? m[0]! : '<сайт>')
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
    final lines = <String>[
      'Ласточка $appVersion',
      'Система: ${Platform.operatingSystem} ${Platform.operatingSystemVersion}',
      'Устройство: ${deviceLabel()}',
      'Режим: ${kReleaseMode ? 'release' : 'debug'}',
      'Вход выполнен: ${client.isLogged() ? 'да' : 'нет'}',
      'Синхронизация: ${client.prevBatch == null ? 'ещё не было' : 'есть'}',
      'Подпись устройств: ${enc?.crossSigning.enabled == true ? 'включена' : 'нет'}',
      'Это устройство подтверждено: ${client.isUnknownSession ? 'нет' : 'да'}',
      'Резервная копия ключей: ${backup == true ? 'есть' : 'нет'}${cached == true ? ', подключена' : ''}',
      'Чатов: ${client.rooms.length}',
      '',
      '— Ошибки приложения —',
      ..._buf,
      '',
      '— Журнал Matrix (предупреждения и ошибки) —',
      for (final e in Logs().outputEvents.where((e) => e.level.index <= Level.warning.index).toList().reversed.take(80).toList().reversed)
        '${e.level.name}: ${e.title}${e.exception != null ? ' — ${e.exception}' : ''}',
    ];
    return scrub(lines.join('\n'), host: client.homeserver?.host, domain: client.userID?.domain);
  }
}
