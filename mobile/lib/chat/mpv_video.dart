// Видео на Windows Server и в RDP-сеансе — собственным проигрывателем (mpv + FFmpeg, пакет media_kit),
// как в Telegram Desktop. Видеомодуль Windows (Media Foundation) на сервере часто неполный и ронял Ласточку,
// поэтому там он не используется вовсе: и кадр-превью, и воспроизведение — через mpv.
//
// Без видеокарты кадр рисуется процессором (программный вывод media_kit). Что здесь сделано против падений:
// • поворот видео с телефона (метка «повернуть на 90°») mpv отдаёт программному выводу, а тот его не умеет:
//   кадр читался как повёрнутый — за пределами памяти, и Ласточка падала в libmpv-2.dll (0xC0000005).
//   Поэтому mpv поворот не передаётся (video-rotate=no), а кадр поворачивается заранее фильтром transpose;
// • размер картинки задаётся явно: сам media_kit для вертикального видео считал ширину 0;
// • преобразование кадров — через libswscale (FFmpeg), а не zimg;
// • декодирование только процессором (hwdec=no): на виртуальном сервере нет видеоускорителя;
// • кадр для превью mpv сохраняет сам (screenshot-to-file), а не через screenshot-raw media_kit;
// • превью делаются по одному, а не все разом;
// • если mpv всё же уронит Ласточку, при следующем запуске эта часть (превью или проигрыватель)
//   отключается до обновления — вместо повторных падений.
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../system/diag.dart';
import 'mp4_rotation.dart';
import '../system/perf.dart' show windowsMediaSafe;
import '../system/updater.dart' show appVersion;

/// Видео через mpv: Windows Server или RDP-сеанс.
final bool useMpv = Platform.isWindows && !windowsMediaSafe;

const _frame = 'frame', _play = 'play';
Future<Set<String>> _off = Future.value(const {});
String? _dir;

void initMpv() {
  if (!useMpv) return;
  try {
    MediaKit.ensureInitialized();
  } catch (e) {
    Diag.err('Проигрыватель видео (mpv)', e);
  }
  _off = _checkLastRun();
}

/// Встроенный проигрыватель отключён после падения mpv (до обновления Ласточки).
Future<bool> mpvPlayOff() async => (await _off).contains(_play);

/// Прошлый запуск оборвался посреди работы mpv? Падение в libmpv — сразу отключаем эту часть,
/// просто оборвался (закрыли через диспетчер задач и т. п.) — только со второго раза подряд.
Future<Set<String>> _checkLastRun() async {
  final off = <String>{};
  try {
    final dir = (await getApplicationSupportDirectory()).path;
    _dir = dir;
    final crash = await Diag.nativeCrash;
    final inMpv = crash != null && crash.toLowerCase().contains('libmpv');
    for (final ph in [_frame, _play]) {
      final busy = File(p.join(dir, 'mpv_$ph.busy'));
      final strikes = File(p.join(dir, 'mpv_$ph.strikes'));
      final offF = File(p.join(dir, 'mpv_$ph.off'));
      if (busy.existsSync()) {
        busy.deleteSync();
        final n = (strikes.existsSync() ? int.tryParse(strikes.readAsStringSync().trim()) ?? 0 : 0) + 1;
        strikes.writeAsStringSync('$n');
        if (inMpv || n >= 2) {
          offF.writeAsStringSync(appVersion);
          Diag.add('Видео (mpv): прошлый запуск упал во время ${ph == _frame ? 'создания превью' : 'воспроизведения'} — '
              'эта часть отключена до обновления Ласточки');
        }
      }
      if (offF.existsSync() && offF.readAsStringSync().trim() == appVersion) off.add(ph);
    }
  } catch (e) {
    Diag.err('Видео (mpv): проверка прошлого запуска', e);
  }
  return off;
}

/// Отметка «mpv сейчас работает» — синхронно, чтобы успела лечь на диск до возможного падения.
void _busy(String ph, bool on) {
  final dir = _dir;
  if (dir == null) return;
  try {
    final f = File(p.join(dir, 'mpv_$ph.busy'));
    if (on) {
      f.writeAsStringSync(DateTime.now().toIso8601String());
    } else {
      if (f.existsSync()) f.deleteSync();
      final s = File(p.join(dir, 'mpv_$ph.strikes'));
      if (s.existsSync()) s.deleteSync();
    }
  } catch (_) {}
}

/// Размер картинки: с пропорциями видео, вписан в [maxW]×[maxH], обе стороны чётные и не меньше 2.
({int w, int h}) fitSize(num? vw, num? vh, int maxW, int maxH) {
  if (vw == null || vh == null || vw <= 0 || vh <= 0) return (w: maxW, h: maxH);
  final k = math.min(1.0, math.min(maxW / vw, maxH / vh));
  int even(num v) => math.max(2, (v.round() ~/ 2) * 2);
  return (w: even(vw * k), h: even(vh * k));
}

Player _newPlayer() => Player(configuration: const PlayerConfiguration(title: 'Ласточка', logLevel: MPVLogLevel.error));

/// Безопасные настройки mpv для сервера без видеокарты — до открытия файла.
Future<void> _safe(Player player) async {
  final n = player.platform;
  if (n is! NativePlayer) return;
  for (final (k, v) in [('video-rotate', 'no'), ('sws-allow-zimg', 'no'), ('hwdec', 'no'), ('screenshot-sw', 'yes'), ('screenshot-jpeg-quality', '85')]) {
    try {
      await n.setProperty(k, v);
    } catch (e) {
      Diag.add('Видео (mpv): не удалось задать $k: $e');
    }
  }
}

/// Поворот видео по метке в самом файле (0, 90, 180, 270 — по часовой). Ждёт, пока mpv откроет файл.
/// Запасной путь: у телефонных MP4/MOV поворот читается из заголовка (mp4Rotation) — эта сборка mpv
/// получает его только из кадров, а там он отключён (video-rotate=no).
Future<int> _mpvRotation(NativePlayer n) async {
  for (var i = 0; i < 100; i++) {
    String id = '';
    try {
      id = await n.getProperty('current-tracks/video/id');
    } catch (_) {
      return 0; // проигрыватель уже закрыт
    }
    if (id.isNotEmpty) break;
    await Future.delayed(const Duration(milliseconds: 100));
  }
  try {
    final r = int.tryParse((await n.getProperty('current-tracks/video/demux-rotation')).trim()) ?? 0;
    return ((r % 360) + 360) % 360;
  } catch (_) {
    return 0; // метки нет — видео не повёрнуто
  }
}

/// Фильтр mpv, поворачивающий кадр заранее (вместо поворота при выводе).
String? _rotateFilter(int rot) => switch (rot) {
      90 => 'lavfi=[transpose=clock]',
      180 => 'lavfi=[hflip,vflip]',
      270 => 'lavfi=[transpose=cclock]',
      _ => null,
    };

VideoController _videoController(Player player, int w, int h) => VideoController(player,
    configuration: VideoControllerConfiguration(enableHardwareAcceleration: false, hwdec: 'no', width: w, height: h));

typedef MpvFrame = ({Uint8List jpeg, int w, int h, int durationMs});

Future<void> _queue = Future.value();

/// Первый кадр видео (JPEG до 480 точек), размеры и длительность — через mpv. null — не получилось.
/// Кадры делаются строго по одному.
Future<MpvFrame?> mpvFrame(String path) {
  final done = Completer<MpvFrame?>();
  _queue = _queue.then((_) async => done.complete(await _makeFrame(path)), onError: (_) {});
  return done.future;
}

Future<MpvFrame?> _makeFrame(String path) async {
  if ((await _off).contains(_frame)) return null;
  final out = File(p.join(Directory.systemTemp.path, 'lastochka_frame_${DateTime.now().microsecondsSinceEpoch}.jpg'));
  Player? player;
  _busy(_frame, true);
  try {
    player = _newPlayer();
    await _safe(player);
    // кадр берётся из самого видео, окно вывода нужно лишь чтобы mpv декодировал — маленькое
    final controller = _videoController(player, 256, 256);
    await player.setVolume(0);
    await player.open(Media(Uri.file(path).toString()), play: false);
    await controller.waitUntilFirstFrameRendered.timeout(const Duration(seconds: 15));
    final n = player.platform;
    if (n is! NativePlayer) return null;
    final rot = await mp4Rotation(path) ?? await _mpvRotation(n);
    await n.command(['screenshot-to-file', out.path, 'video']);
    if (!out.existsSync()) return null;
    // mpv снимает кадр без поворота — поворачиваем сами
    final small = await compute(_shrink, (await out.readAsBytes(), rot));
    if (small == null) return null;
    return (jpeg: small.jpeg, w: small.w, h: small.h, durationMs: player.state.duration.inMilliseconds);
  } catch (e, st) {
    Diag.err('Кадр из видео (mpv)', e, st);
    return null;
  } finally {
    try {
      await player?.dispose();
    } catch (_) {}
    try {
      if (out.existsSync()) out.deleteSync();
    } catch (_) {}
    _busy(_frame, false);
  }
}

/// Уменьшить кадр до 480 точек по большей стороне. w, h — размеры самого кадра (видео).
({Uint8List jpeg, int w, int h})? _shrink((Uint8List, int) a) {
  final (bytes, rot) = a;
  var im = img.decodeImage(bytes);
  if (im == null || im.width <= 0 || im.height <= 0) return null;
  if (rot != 0) im = img.copyRotate(im, angle: rot);
  final big = math.max(im.width, im.height);
  final s = big > 480 ? img.copyResize(im, width: im.width * 480 ~/ big, height: im.height * 480 ~/ big, interpolation: img.Interpolation.average) : im;
  return (jpeg: img.encodeJpg(s, quality: 82), w: im.width, h: im.height);
}

/// Проигрыватель внутри Ласточки (mpv): пауза, перемотка, громкость, полный экран — как в Telegram.
class MpvVideoView extends StatefulWidget {
  final File file;
  final bool autoplay;
  /// Размеры видео из сообщения (если отправитель их указал).
  final num? videoW, videoH;
  final VoidCallback onFailed;
  const MpvVideoView({super.key, required this.file, required this.onFailed, this.autoplay = true, this.videoW, this.videoH});
  @override
  State<MpvVideoView> createState() => _MpvVideoViewState();
}

class _MpvVideoViewState extends State<MpvVideoView> {
  final Player _player = _newPlayer();
  VideoController? _controller;
  StreamSubscription? _err;

  @override
  void initState() {
    super.initState();
    _err = _player.stream.error.listen((e) {
      Diag.add('Воспроизведение видео (mpv): $e');
    });
    _start();
  }

  Future<void> _start() async {
    try {
      if (await mpvPlayOff()) {
        if (mounted) widget.onFailed();
        return;
      }
      _busy(_play, true);
      Diag.mark('видео (mpv): воспроизведение');
      await _safe(_player);
      if (!mounted) return;
      // RDP: картинка не больше 1280×720 — её рисует процессор сервера и передаёт RDP
      final s = fitSize(widget.videoW, widget.videoH, 1280, 720);
      setState(() => _controller = _videoController(_player, s.w, s.h));
      final n = _player.platform;
      // поворот — до открытия файла, чтобы видео сразу стояло правильно
      final rot = await mp4Rotation(widget.file.path);
      final f = _rotateFilter(rot ?? 0);
      if (f != null && n is NativePlayer) await n.setProperty('vf', f);
      await _player.open(Media(Uri.file(widget.file.path).toString()), play: false);
      if (rot == null && n is NativePlayer) {
        final f2 = _rotateFilter(await _mpvRotation(n));
        if (f2 != null) await n.setProperty('vf', f2);
      }
      if (mounted && widget.autoplay) await _player.play();
    } catch (e, st) {
      Diag.err('Воспроизведение видео (mpv)', e, st);
      if (mounted) widget.onFailed();
    }
  }

  @override
  void dispose() {
    _err?.cancel();
    _player.dispose().whenComplete(() {
      _busy(_play, false);
      Diag.mark('видео (mpv): воспроизведение — готово');
    });
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = _controller;
    if (c == null) return const Center(child: CircularProgressIndicator());
    return Video(
      controller: c,
      controls: MaterialDesktopVideoControls,
      fill: Colors.black,
    );
  }
}
