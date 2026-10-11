// Подробности звонка для «Отчёта для диагностики»: как соединились (напрямую или через сервер),
// задержка, потери звука, кодек, качество видео. Ничего о собеседнике и содержании разговора.
import 'dart:async';

import 'package:matrix/matrix.dart';
import 'package:webrtc_interface/webrtc_interface.dart';

import '../system/diag.dart';

class CallStats {
  static final _timers = <String, Timer>{};
  static final _last = <String, String>{};
  static final _start = <String, DateTime>{};

  /// Начать следить за звонком: раз в 5 секунд снимаем показатели, итог — при завершении.
  static void watch(CallSession s) {
    final kind = '${s.isOutgoing ? 'исходящий' : 'входящий'} ${s.type == CallType.kVideo ? 'видео' : 'аудио'}';
    Diag.add('Звонок: $kind');
    s.onCallStateChanged.stream.listen((st) {
      if (st == CallState.kConnected && !_timers.containsKey(s.callId)) {
        _start[s.callId] = DateTime.now();
        Diag.mark('звонок: соединение установлено');
        _sample(s);
        _timers[s.callId] = Timer.periodic(const Duration(seconds: 5), (_) => _sample(s));
      }
    });
  }

  static Future<void> _sample(CallSession s) async {
    final pc = s.pc;
    if (pc == null) return;
    try {
      _last[s.callId] = summarize(await pc.getStats());
    } catch (e) {
      Diag.err('Показатели звонка', e);
    }
  }

  /// Звонок завершён: итог — в отчёт («Последний звонок») и в журнал.
  static void ended(CallSession s) {
    _timers.remove(s.callId)?.cancel();
    final start = _start.remove(s.callId);
    final stats = _last.remove(s.callId);
    final dur = start == null ? 'не соединились' : _dur(DateTime.now().difference(start));
    final reason = s.hangupReason == null ? '' : ', причина: ${s.hangupReason!.reason}';
    final text = '$dur$reason${stats == null ? '' : '; $stats'}';
    Diag.lastCall = text;
    Diag.add('Звонок завершён: $text');
  }

  static String _dur(Duration d) => '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';

  /// Сводка показателей WebRTC в одну строку.
  static String summarize(List<StatsReport> reports) {
    final byId = {for (final r in reports) r.id: r};
    Map<dynamic, dynamic>? v(StatsReport? r) => r?.values;

    // выбранная пара кандидатов — по ней понятно, как идёт звук: напрямую или через сервер
    StatsReport? pair;
    for (final r in reports.where((r) => r.type == 'transport')) {
      final id = v(r)?['selectedCandidatePairId'];
      if (id != null) pair = byId['$id'];
    }
    pair ??= reports.where((r) => r.type == 'candidate-pair' && v(r)?['state'] == 'succeeded' && v(r)?['nominated'] == true).firstOrNull;
    final parts = <String>[];
    if (pair != null) {
      final local = v(byId['${v(pair)?['localCandidateId']}']);
      final remote = v(byId['${v(pair)?['remoteCandidateId']}']);
      final lt = '${local?['candidateType'] ?? ''}', rt = '${remote?['candidateType'] ?? ''}';
      final how = lt == 'relay' || rt == 'relay'
          ? 'через сервер TURN'
          : (lt == 'host' && rt == 'host')
              ? 'напрямую в локальной сети'
              : 'напрямую через интернет';
      parts.add('соединение: $how (${local?['protocol'] ?? '?'})');
      final rtt = v(pair)?['currentRoundTripTime'];
      if (rtt is num) parts.add('задержка ${(rtt * 1000).round()} мс');
    } else {
      parts.add('соединение: не выбрано');
    }
    for (final r in reports.where((r) => r.type == 'inbound-rtp')) {
      final m = v(r)!;
      final kind = m['kind'] ?? m['mediaType'];
      if (kind == 'audio') {
        final lost = (m['packetsLost'] as num?)?.toInt() ?? 0;
        final got = (m['packetsReceived'] as num?)?.toInt() ?? 0;
        final pct = got + lost == 0 ? 0 : lost * 100 / (got + lost);
        parts.add('потери звука ${pct.toStringAsFixed(1)}% ($lost из ${got + lost})');
        final j = m['jitter'];
        if (j is num) parts.add('джиттер ${(j * 1000).round()} мс');
        final codec = v(byId['${m['codecId']}'])?['mimeType'];
        if (codec != null) parts.add('кодек ${'$codec'.replaceFirst('audio/', '')}');
        if (got == 0) parts.add('звук от собеседника не приходил');
      } else if (kind == 'video') {
        final w = m['frameWidth'], h = m['frameHeight'], fps = m['framesPerSecond'];
        if (w != null && h != null) parts.add('видео ${w}x$h${fps is num ? ' ${fps.round()} к/с' : ''}');
      }
    }
    final out = reports.where((r) => r.type == 'outbound-rtp' && (v(r)?['kind'] ?? v(r)?['mediaType']) == 'audio').firstOrNull;
    final sent = (v(out)?['packetsSent'] as num?)?.toInt();
    if (sent == 0) parts.add('ваш микрофон ничего не передавал');
    return parts.join('; ');
  }
}
