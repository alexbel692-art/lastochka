// Голосовые сообщения: запись с волной и проигрывание (формат как в настольной Ласточке и Element:
// m.audio + org.matrix.msc3245.voice + org.matrix.msc1767.audio {duration мс, waveform 0..1024}).
import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart';
import 'package:path/path.dart' as p;
import 'package:record/record.dart';

import '../system/trust.dart';
import '../system/privacy.dart';
import '../system/diag.dart';

String fmtDur(int ms) {
  final s = (ms / 1000).round();
  return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
}

List<int> waveformFrom(List<double> levels, {int n = 64}) {
  if (levels.isEmpty) return List.filled(n, 200);
  final mx = max(levels.reduce(max), 0.01);
  return [
    for (var i = 0; i < n; i++)
      () {
        final a = i * levels.length ~/ n, b = max(a + 1, (i + 1) * levels.length ~/ n);
        var m = 0.0;
        for (var j = a; j < b && j < levels.length; j++) {
          m = max(m, levels[j]);
        }
        return (min(1.0, m / mx) * 1024).round();
      }(),
  ];
}

/// Запись голосового.
class VoiceRecorder {
  final _rec = AudioRecorder();
  StreamSubscription<Amplitude>? _amp;
  final levels = <double>[];
  DateTime? started;
  String? _path;

  /// Начать запись. Возвращает текст ошибки или null.
  Future<String?> start() async {
    try {
      if (!await _rec.hasPermission()) return 'Нет доступа к микрофону';
      if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
        final devices = await _rec.listInputDevices();
        if (devices.isEmpty) {
          return 'Микрофон не найден. На удалённом рабочем столе включите в настройках подключения «Запись звука с этого компьютера»';
        }
      }
      // AAC (m4a) — как на телефонах; если система его не умеет или микрофон не принимает формат
      // (так бывает на удалённом рабочем столе: «тип носителя недопустим») — пробуем другие частоты и WAV
      final aac = await _rec.isEncoderSupported(AudioEncoder.aacLc);
      final dir = await privateTemp();
      levels.clear();
      final tries = <RecordConfig>[
        if (aac) const RecordConfig(encoder: AudioEncoder.aacLc, bitRate: 48000, sampleRate: 44100, numChannels: 1),
        if (aac) const RecordConfig(encoder: AudioEncoder.aacLc, bitRate: 64000, sampleRate: 48000, numChannels: 2),
        const RecordConfig(encoder: AudioEncoder.wav, sampleRate: 48000, numChannels: 1),
        const RecordConfig(encoder: AudioEncoder.wav, sampleRate: 44100, numChannels: 2),
        const RecordConfig(encoder: AudioEncoder.wav, sampleRate: 16000, numChannels: 1),
      ];
      Object? last;
      var ok = false;
      for (final cfg in tries) {
        final wav = cfg.encoder == AudioEncoder.wav;
        _path = p.join(dir.path, 'voice_${DateTime.now().millisecondsSinceEpoch}.${wav ? 'wav' : 'm4a'}');
        try {
          await _rec.start(cfg, path: _path!);
          _wav = wav;
          ok = true;
          break;
        } catch (e) {
          last = e;
          try {
            await _rec.stop();
          } catch (_) {}
        }
      }
      if (!ok) throw last ?? 'запись не началась';
      started = DateTime.now();
      _seg = started;
      _accum = 0;
      paused = false;
      _amp = _rec.onAmplitudeChanged(const Duration(milliseconds: 80)).listen((a) {
        if (paused) return;
        final db = a.current.isFinite ? a.current : -60.0;
        levels.add(pow(10, max(-60.0, db) / 20).toDouble());
      });
      return null;
    } catch (e, st) {
      Diag.err('Запись голосового', e, st);
      return 'Не удалось включить микрофон';
    }
  }

  bool _wav = false;
  /// Формат последней записи — для отправки.
  bool get isWav => _wav;

  // пауза: время на паузе в длительность не входит
  int _accum = 0;
  DateTime? _seg;
  bool paused = false;

  int get elapsedMs => started == null ? 0 : _accum + (paused || _seg == null ? 0 : DateTime.now().difference(_seg!).inMilliseconds);

  /// Пауза записи. Возвращает текст ошибки или null.
  Future<String?> pause() async {
    if (started == null || paused) return null;
    try {
      await _rec.pause();
      _accum += DateTime.now().difference(_seg!).inMilliseconds;
      paused = true;
      return null;
    } catch (e) {
      Diag.err('Пауза записи', e);
      return 'Пауза здесь недоступна';
    }
  }

  Future<String?> resume() async {
    if (started == null || !paused) return null;
    try {
      await _rec.resume();
      _seg = DateTime.now();
      paused = false;
      return null;
    } catch (e) {
      Diag.err('Продолжение записи', e);
      return 'Не удалось продолжить запись';
    }
  }

  /// Остановить; вернуть файл, длительность и волну. null — слишком короткое.
  Future<(File, int, List<int>)?> stop() async {
    final dur = elapsedMs;
    await _amp?.cancel();
    final path = await _rec.stop() ?? _path;
    started = null;
    paused = false;
    if (path == null || dur < 700) return null;
    return (File(path), dur, waveformFrom(levels));
  }

  Future<void> cancel() async {
    await _amp?.cancel();
    started = null;
    paused = false;
    try {
      await _rec.cancel();
    } catch (_) {}
  }

  void dispose() => _rec.dispose();
}

Future<void> sendVoice(Room room, File f, int durationMs, List<int> waveform, {Event? inReplyTo, Map<String, Object> extra = const {}}) async {
  final bytes = await f.readAsBytes();
  final wav = f.path.toLowerCase().endsWith('.wav');
  ensureCanSend(room);
  await room.sendFileEvent(
    MatrixAudioFile(bytes: bytes, name: 'Голосовое сообщение.${wav ? 'wav' : 'm4a'}', mimeType: wav ? 'audio/wav' : 'audio/mp4', duration: durationMs),
    inReplyTo: inReplyTo,
    extraContent: {
      'body': 'Голосовое сообщение',
      'filename': 'Голосовое сообщение.${wav ? 'wav' : 'm4a'}',
      'org.matrix.msc1767.text': 'Голосовое сообщение',
      'org.matrix.msc1767.audio': {'duration': durationMs, 'waveform': waveform},
      'org.matrix.msc3245.voice': <String, Object?>{},
      ...extra,
    },
  );
  try {
    await f.delete();
  } catch (_) {}
}

/// Один проигрыватель на всё приложение: включили новое — предыдущее остановилось.
class VoicePlayback extends ChangeNotifier {
  VoicePlayback._() {
    _player.onPositionChanged.listen((d) {
      position = d;
      notifyListeners();
    });
    _player.onPlayerComplete.listen((_) {
      playing = false;
      position = Duration.zero;
      current = null;
      notifyListeners();
    });
  }
  static final instance = VoicePlayback._();
  final _player = AudioPlayer();
  final Map<String, String> _files = {};
  String? current;
  bool playing = false, loading = false;
  Duration position = Duration.zero;
  double rate = 1.0;

  Future<void> toggle(Event e) async {
    if (current == e.eventId) {
      playing ? await _player.pause() : await _player.resume();
      playing = !playing;
      notifyListeners();
      return;
    }
    await _player.stop();
    // расшифрованная копия предыдущего голосового больше не нужна
    for (final old in _files.entries.where((x) => x.key != e.eventId).toList()) {
      try {
        await File(old.value).delete();
      } catch (_) {}
      _files.remove(old.key);
    }
    current = e.eventId;
    position = Duration.zero;
    loading = true;
    notifyListeners();
    try {
      var path = _files[e.eventId];
      if (path == null) {
        // голосовое не бывает огромным — слишком большой «голосовой» файл не загружаем
        final size = (e.content.tryGetMap<String, Object?>('info')?['size'] as num?)?.toInt() ?? 0;
        if (size > 25 * 1024 * 1024) throw Exception('слишком большой файл');
        final f = await e.downloadAndDecryptAttachment();
        final mime = e.content.tryGetMap<String, Object?>('info')?['mimetype']?.toString() ?? '';
        final ext = mime.contains('ogg') ? 'ogg' : mime.contains('webm') ? 'webm' : mime.contains('mpeg') ? 'mp3' : mime.contains('wav') ? 'wav' : 'm4a';
        path = p.join((await privateTemp()).path, 'play_${tempKey(e.eventId)}.$ext');
        await File(path).writeAsBytes(f.bytes, flush: true);
        _files[e.eventId] = path;
      }
      await _player.setPlaybackRate(rate);
      await _player.play(DeviceFileSource(path));
      playing = true;
    } catch (err) {
      current = null;
      playing = false;
    }
    loading = false;
    notifyListeners();
  }

  Future<void> seek(Event e, double frac) async {
    if (current != e.eventId) return;
    final d = await _player.getDuration();
    if (d != null) await _player.seek(d * frac);
  }

  Future<void> cycleRate() async {
    rate = rate == 1.0 ? 1.5 : rate == 1.5 ? 2.0 : 1.0;
    try {
      await _player.setPlaybackRate(rate);
    } catch (_) {}
    notifyListeners();
  }
}

/// Пузырь голосового: кнопка, волна, время, скорость.
class VoiceMessage extends StatelessWidget {
  final Event event;
  final Color color;
  const VoiceMessage({super.key, required this.event, required this.color});

  @override
  Widget build(BuildContext context) {
    final audio = event.content.tryGetMap<String, Object?>('org.matrix.msc1767.audio');
    final info = event.content.tryGetMap<String, Object?>('info');
    final dur = ((audio?['duration'] ?? info?['duration']) as num?)?.toInt() ?? 0;
    final wf = (audio?['waveform'] is List) ? (audio!['waveform'] as List).whereType<num>().map((x) => x.toInt()).toList() : <int>[];
    final isVoice = event.content.containsKey('org.matrix.msc3245.voice') || event.content.containsKey('org.matrix.msc2516.voice');
    final hint = Theme.of(context).hintColor;
    return ListenableBuilder(
      listenable: VoicePlayback.instance,
      builder: (context, _) {
        final pb = VoicePlayback.instance;
        final on = pb.current == event.eventId;
        final frac = on && dur > 0 ? (pb.position.inMilliseconds / dur).clamp(0.0, 1.0) : 0.0;
        return Row(mainAxisSize: MainAxisSize.min, children: [
          GestureDetector(
            onTap: () => pb.toggle(event),
            child: Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              child: on && pb.loading
                  ? const Padding(padding: EdgeInsets.all(12), child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : Icon(on && pb.playing ? Icons.pause : Icons.play_arrow, color: Colors.white, size: 28),
            ),
          ),
          const SizedBox(width: 10),
          Flexible(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              if (!isVoice) Text(event.body, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w500)),
              LayoutBuilder(builder: (context, box) {
                final w = min(box.maxWidth, 190.0);
                return GestureDetector(
                  onTapDown: (d) => pb.seek(event, (d.localPosition.dx / w).clamp(0.0, 1.0)),
                  child: CustomPaint(size: Size(w, 26), painter: _Wave(wf, frac, color, hint.withValues(alpha: 0.45))),
                );
              }),
              const SizedBox(height: 2),
              Row(mainAxisSize: MainAxisSize.min, children: [
                Text(on && pb.position > Duration.zero ? fmtDur(pb.position.inMilliseconds) : fmtDur(dur), style: TextStyle(fontSize: 12, color: hint)),
                if (on) ...[
                  const SizedBox(width: 8),
                  GestureDetector(
                    onTap: pb.cycleRate,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                      decoration: BoxDecoration(color: color.withValues(alpha: 0.18), borderRadius: BorderRadius.circular(8)),
                      child: Text('${pb.rate == pb.rate.roundToDouble() ? pb.rate.toInt() : pb.rate}×', style: TextStyle(fontSize: 11, color: color, fontWeight: FontWeight.w700)),
                    ),
                  ),
                ],
              ]),
            ]),
          ),
        ]);
      },
    );
  }
}

class _Wave extends CustomPainter {
  final List<int> wf;
  final double frac;
  final Color on, off;
  _Wave(this.wf, this.frac, this.on, this.off);

  @override
  void paint(Canvas c, Size s) {
    const bw = 3.0, gap = 2.0;
    final n = (s.width / (bw + gap)).floor();
    final src = wf.isEmpty ? List.filled(n, 300) : wf;
    for (var i = 0; i < n; i++) {
      final v = src[(i * src.length / n).floor().clamp(0, src.length - 1)] / 1024;
      final h = max(3.0, v * s.height);
      final x = i * (bw + gap);
      final paint = Paint()..color = (i / n) <= frac ? on : off;
      c.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(x, (s.height - h) / 2, bw, h), const Radius.circular(1.5)), paint);
    }
  }

  @override
  bool shouldRepaint(_Wave o) => o.frac != frac || o.wf != wf || o.on != on;
}

/// Записанное голосовое перед отправкой: прослушать, удалить или отправить (как в Telegram).
class VoiceReviewBar extends StatefulWidget {
  final File file;
  final int durationMs;
  final List<int> waveform;
  final VoidCallback onSend, onDelete;
  const VoiceReviewBar({super.key, required this.file, required this.durationMs, required this.waveform, required this.onSend, required this.onDelete});
  @override
  State<VoiceReviewBar> createState() => _VoiceReviewBarState();
}

class _VoiceReviewBarState extends State<VoiceReviewBar> {
  final _player = AudioPlayer();
  final _subs = <StreamSubscription>[];
  bool _playing = false;
  Duration _pos = Duration.zero;

  @override
  void initState() {
    super.initState();
    _subs
      ..add(_player.onPositionChanged.listen((d) => mounted ? setState(() => _pos = d) : null))
      ..add(_player.onPlayerComplete.listen((_) => mounted ? setState(() {
            _playing = false;
            _pos = Duration.zero;
          }) : null));
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    _player.dispose();
    super.dispose();
  }

  Future<void> _toggle() async {
    try {
      if (_playing) {
        await _player.pause();
      } else if (_pos > Duration.zero) {
        await _player.resume();
      } else {
        await _player.play(DeviceFileSource(widget.file.path));
      }
      setState(() => _playing = !_playing);
    } catch (e) {
      Diag.err('Прослушивание голосового', e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    final hint = Theme.of(context).hintColor;
    final frac = widget.durationMs > 0 ? (_pos.inMilliseconds / widget.durationMs).clamp(0.0, 1.0) : 0.0;
    final wf = widget.waveform.isEmpty ? List.filled(40, 8) : widget.waveform;
    return SizedBox(
      height: 56,
      child: Row(children: [
        IconButton(tooltip: 'Удалить', icon: const Icon(Icons.delete_outline, color: Colors.redAccent), onPressed: widget.onDelete),
        IconButton(tooltip: _playing ? 'Пауза' : 'Прослушать', icon: Icon(_playing ? Icons.pause_circle_filled : Icons.play_circle_fill, color: accent, size: 32), onPressed: _toggle),
        Expanded(
          child: LayoutBuilder(builder: (_, c) {
            final n = max(10, min(wf.length, (c.maxWidth / 4).floor()));
            return Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
              for (var i = 0; i < n; i++)
                Expanded(
                  child: Container(
                    margin: const EdgeInsets.symmetric(horizontal: 0.6),
                    height: 4 + 20 * (wf[(i * wf.length / n).floor().clamp(0, wf.length - 1)] / 1024).clamp(0.0, 1.0),
                    decoration: BoxDecoration(color: i / n <= frac ? accent : hint.withValues(alpha: 0.4), borderRadius: BorderRadius.circular(2)),
                  ),
                ),
            ]);
          }),
        ),
        const SizedBox(width: 8),
        Text(fmtDur(_playing || _pos > Duration.zero ? _pos.inMilliseconds : widget.durationMs), style: const TextStyle(fontSize: 14, fontFeatures: [FontFeature.tabularFigures()])),
        Padding(
          padding: const EdgeInsets.only(left: 4, right: 8),
          child: IconButton.filled(tooltip: 'Отправить', onPressed: widget.onSend, icon: const Icon(Icons.arrow_upward)),
        ),
      ]),
    );
  }
}
