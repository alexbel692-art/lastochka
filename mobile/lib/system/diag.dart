// Отчёт для диагностики: версия, устройство, последние ошибки. Без переписки: адреса, имена,
// идентификаторы, ссылки и пути к файлам вырезаются, поэтому отчёт можно спокойно переслать.
import 'dart:io';
import 'dart:ui';

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
  static String scrub(String s, {String? host}) {
    var r = s
        .replaceAll(RegExp(r'@[^\s:]+:[A-Za-z0-9.\-]+'), '@<пользователь>')
        .replaceAll(RegExp(r'![A-Za-z0-9]+:[A-Za-z0-9.\-]+'), '!<чат>')
        .replaceAll(RegExp(r'#[^\s:]+:[A-Za-z0-9.\-]+'), '#<чат>')
        .replaceAll(RegExp(r'\$[A-Za-z0-9_\-+/]{20,}'), r'$<событие>')
        .replaceAll(RegExp(r'mxc://\S+'), 'mxc://<файл>')
        .replaceAll(RegExp(r'https?://[^\s/]+'), '<адрес>')
        .replaceAll(RegExp(r'\b\d{1,3}(\.\d{1,3}){3}\b'), '<ip>')
        .replaceAll(RegExp(r'[\w.+-]+@[\w-]+\.[\w.]+'), '<почта>')
        .replaceAll(RegExp(r'(syt|syt_|mat_|Bearer )\S+'), '<токен>')
        .replaceAllMapped(RegExp(r'(/Users/|/home/|\\Users\\)[^/\\\s]+'), (m) => '${m[1]}<имя>');
    if (host != null && host.isNotEmpty) r = r.replaceAll(host, '<сервер>');
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
    return scrub(lines.join('\n'), host: client.homeserver?.host);
  }
}
