// Звуки звонка — те же, что в настольной Ласточке: синтезируются на лету, без файлов.
import 'dart:math';
import 'dart:typed_data';

import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

const _rate = 22050;

/// Синус с плавным нарастанием и затуханием. [parts]: (частоты, начало с, длительность с, громкость).
Uint8List _wav(double total, List<(List<double>, double, double, double)> parts) {
  final n = (total * _rate).round();
  final pcm = Float64List(n);
  for (final (freqs, start, dur, vol) in parts) {
    final s0 = (start * _rate).round(), len = (dur * _rate).round();
    final fade = (0.04 * _rate).round();
    for (var i = 0; i < len && s0 + i < n; i++) {
      final env = min(1.0, min(i / fade, (len - i) / fade));
      var v = 0.0;
      for (final f in freqs) {
        v += sin(2 * pi * f * i / _rate);
      }
      pcm[s0 + i] += v / freqs.length * vol * env;
    }
  }
  final b = ByteData(44 + n * 2);
  void str(int o, String s) {
    for (var i = 0; i < s.length; i++) {
      b.setUint8(o + i, s.codeUnitAt(i));
    }
  }

  str(0, 'RIFF');
  b.setUint32(4, 36 + n * 2, Endian.little);
  str(8, 'WAVE');
  str(12, 'fmt ');
  b.setUint32(16, 16, Endian.little);
  b.setUint16(20, 1, Endian.little);
  b.setUint16(22, 1, Endian.little);
  b.setUint32(24, _rate, Endian.little);
  b.setUint32(28, _rate * 2, Endian.little);
  b.setUint16(32, 2, Endian.little);
  b.setUint16(34, 16, Endian.little);
  str(36, 'data');
  b.setUint32(40, n * 2, Endian.little);
  for (var i = 0; i < n; i++) {
    b.setInt16(44 + i * 2, (pcm[i].clamp(-1.0, 1.0) * 32767).round(), Endian.little);
  }
  return b.buffer.asUint8List();
}

final _incoming = _wav(2.0, [([660, 880], 0, 1.0, 0.5)]);
final _outgoing = _wav(4.0, [([425], 0, 1.1, 0.3)]);
final _hangup = _wav(0.5, [([660], 0, 0.2, 0.5), ([440], 0.22, 0.2, 0.5)]);

class CallSounds {
  CallSounds._();
  static final _loop = AudioPlayer();
  static final _once = AudioPlayer();
  static bool _ready = false;

  static Future<void> _init() async {
    if (_ready) return;
    _ready = true;
    // не отнимать звук у самого звонка
    final ctx = AudioContextConfig(focus: AudioContextConfigFocus.mixWithOthers).build();
    await _loop.setAudioContext(ctx);
    await _once.setAudioContext(ctx);
    await _loop.setReleaseMode(ReleaseMode.loop);
  }

  // звуки сохраняются во временные файлы: проигрывание из памяти поддерживается не на всех системах
  static final Map<String, String> _files = {};
  static Future<Source> _src(String name, Uint8List wav) async {
    var path = _files[name];
    if (path == null || !File(path).existsSync()) {
      path = p.join((await getTemporaryDirectory()).path, 'lastochka_$name.wav');
      await File(path).writeAsBytes(wav, flush: true);
      _files[name] = path;
    }
    return DeviceFileSource(path);
  }

  static Future<void> _play(String name, Uint8List wav) async {
    try {
      await _init();
      await _loop.stop();
      await _loop.play(await _src(name, wav));
    } catch (_) {}
  }

  static Future<void> incoming() => _play('incoming', _incoming);
  static Future<void> outgoing() => _play('outgoing', _outgoing);

  static Future<void> stop() async {
    try {
      await _loop.stop();
    } catch (_) {}
  }

  static DateTime _lastHangup = DateTime(2000);

  /// Сигнал завершения звонка. Звучит один раз, чуть позже конца звонка — когда модуль звонков
  /// отпустит динамик (иначе на Android звук мог «съедаться»).
  static Future<void> hangup() async {
    if (DateTime.now().difference(_lastHangup).inSeconds < 2) return;
    _lastHangup = DateTime.now();
    try {
      await _init();
      await _loop.stop();
    } catch (_) {}
    await Future.delayed(const Duration(milliseconds: 350));
    for (var attempt = 0; attempt < 2; attempt++) {
      final pl = AudioPlayer();
      try {
        await pl.setReleaseMode(ReleaseMode.release);
        await pl.play(await _src('hangup', _hangup), volume: 1.0);
        Future.delayed(const Duration(seconds: 2), pl.dispose);
        return;
      } catch (_) {
        pl.dispose();
        await Future.delayed(const Duration(milliseconds: 300));
      }
    }
  }
}
