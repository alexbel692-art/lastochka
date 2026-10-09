// Голосовые сообщения: запись с волной и проигрывание (формат как в настольной Ласточке и Element:
// m.audio + org.matrix.msc3245.voice + org.matrix.msc1767.audio {duration мс, waveform 0..1024}).
import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

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

  Future<bool> start() async {
    if (!await _rec.hasPermission()) return false;
    final dir = await getTemporaryDirectory();
    _path = p.join(dir.path, 'voice_${DateTime.now().millisecondsSinceEpoch}.m4a');
    levels.clear();
    await _rec.start(const RecordConfig(encoder: AudioEncoder.aacLc, bitRate: 48000, sampleRate: 44100, numChannels: 1), path: _path!);
    started = DateTime.now();
    _amp = _rec.onAmplitudeChanged(const Duration(milliseconds: 80)).listen((a) {
      final db = a.current.isFinite ? a.current : -60.0;
      levels.add(pow(10, max(-60.0, db) / 20).toDouble());
    });
    return true;
  }

  int get elapsedMs => started == null ? 0 : DateTime.now().difference(started!).inMilliseconds;

  /// Остановить; вернуть файл, длительность и волну. null — слишком короткое.
  Future<(File, int, List<int>)?> stop() async {
    final dur = elapsedMs;
    await _amp?.cancel();
    final path = await _rec.stop() ?? _path;
    started = null;
    if (path == null || dur < 700) return null;
    return (File(path), dur, waveformFrom(levels));
  }

  Future<void> cancel() async {
    await _amp?.cancel();
    started = null;
    try {
      await _rec.cancel();
    } catch (_) {}
  }

  void dispose() => _rec.dispose();
}

Future<void> sendVoice(Room room, File f, int durationMs, List<int> waveform, {Event? inReplyTo, Map<String, Object> extra = const {}}) async {
  final bytes = await f.readAsBytes();
  await room.sendFileEvent(
    MatrixAudioFile(bytes: bytes, name: 'Голосовое сообщение.m4a', mimeType: 'audio/mp4', duration: durationMs),
    inReplyTo: inReplyTo,
    extraContent: {
      'body': 'Голосовое сообщение',
      'filename': 'Голосовое сообщение.m4a',
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
    current = e.eventId;
    position = Duration.zero;
    loading = true;
    notifyListeners();
    try {
      var path = _files[e.eventId];
      if (path == null) {
        final f = await e.downloadAndDecryptAttachment();
        final mime = e.content.tryGetMap<String, Object?>('info')?['mimetype']?.toString() ?? '';
        final ext = mime.contains('ogg') ? 'ogg' : mime.contains('webm') ? 'webm' : mime.contains('mpeg') ? 'mp3' : 'm4a';
        path = p.join((await getTemporaryDirectory()).path, 'play_${e.eventId.hashCode.abs()}.$ext');
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
