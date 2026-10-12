// Сверка часов устройства с сервером. Подтверждение входа (сравнение эмодзи) Matrix отменяет
// с кодом m.timeout, если часы двух устройств расходятся больше чем на 5 минут, — поэтому
// неправильное время нужно заметить и подсказать, как исправить.
import 'dart:io';

import '../main.dart';
import 'diag.dart';

Duration? _skew;
DateTime? _at;

/// Насколько часы устройства спешат (+) или отстают (−) от сервера. null — не удалось узнать.
Future<Duration?> clockSkew({bool fresh = false}) async {
  if (!fresh && _at != null && DateTime.now().difference(_at!).inMinutes < 10) return _skew;
  try {
    final hs = client.homeserver;
    if (hs == null) return null;
    final sent = DateTime.now();
    final r = await client.httpClient.get(hs.resolve('/_matrix/client/versions')).timeout(const Duration(seconds: 15));
    final got = DateTime.now();
    final date = r.headers['date'];
    if (date == null) return null;
    final server = HttpDate.parse(date);
    // середина запроса — ближе всего к моменту, когда сервер поставил время
    final local = sent.add(got.difference(sent) ~/ 2);
    _skew = local.difference(server);
    _at = DateTime.now();
    if (_skew!.inSeconds.abs() > 120) Diag.add('Часы устройства расходятся с сервером: ${skewText(_skew!)}');
    return _skew;
  } catch (e) {
    Diag.err('Сверка часов', e);
    return null;
  }
}

/// Разница существенна для подтверждения устройств (с запасом: Matrix допускает 5 минут).
bool skewMatters(Duration? d) => d != null && d.inSeconds.abs() >= 180;

String skewText(Duration d) {
  final m = (d.inSeconds.abs() / 60).round();
  final n = m < 1 ? 'меньше минуты' : '$m мин';
  return d.isNegative ? 'отстают на $n' : 'спешат на $n';
}

const fixClockHint = 'Включите автоматическую установку даты и времени (на Windows: Параметры → Время и язык → «Установить время автоматически» и «Синхронизировать»; на телефоне: Настройки → Дата и время → «Автоматически»).';
