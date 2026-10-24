// Видео на Windows Server и в RDP-сеансе — собственным проигрывателем (mpv + FFmpeg, пакет media_kit),
// как в Telegram Desktop. Видеомодуль Windows (Media Foundation) на сервере часто неполный и ронял Ласточку,
// поэтому там он не используется вовсе: и кадр-превью, и воспроизведение — через mpv.
//
// Без видеокарты кадр рисуется процессором (программный вывод media_kit). Что здесь сделано против падений:
// • поворот видео с телефона (метка «повернуть на 90°») mpv отдаёт программному выводу, а тот его не умеет:
//   кадр читался как повёрнутый — за пределами памяти, и Ласточка падала в libmpv-2.dll (0xC0000005).
//   Поэтому mpv поворот не передаётся (video-rotate=no), а картинку поворачивает сама Ласточка при показе
//   (фильтр поворота mpv на сервере давал чёрный экран);
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
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:window_manager/window_manager.dart';

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
///
/// Поворот видео с телефона делает сама Ласточка при показе (RotatedBox): mpv на сервере отдаёт кадр
/// как записан — и с поворотом в mpv (падение), и с фильтром поворота (чёрный экран) он не справлялся.
/// Поэтому и кнопки управления свои: повернуть надо только картинку, а не их.
class MpvVideoView extends StatefulWidget {
  final File file;
  final bool autoplay;
  /// Размеры видео из сообщения (если отправитель их указал) — как его видит человек, уже повёрнутым.
  final num? videoW, videoH;
  final VoidCallback onFailed;
  const MpvVideoView({super.key, required this.file, required this.onFailed, this.autoplay = true, this.videoW, this.videoH});
  @override
  State<MpvVideoView> createState() => _MpvVideoViewState();
}

class _MpvVideoViewState extends State<MpvVideoView> {
  final Player _player = _newPlayer();
  VideoController? _controller;
  int _rot = 0; // поворот по часовой: 0, 90, 180, 270
  final _subs = <StreamSubscription>[];
  int _logged = 0;

  @override
  void initState() {
    super.initState();
    _subs.add(_player.stream.error.listen((e) => Diag.add('Воспроизведение видео (mpv): $e')));
    // сообщения самого mpv (только ошибки) — в отчёт, не больше 20 за просмотр
    _subs.add(_player.stream.log.listen((l) {
      if (_logged++ < 20) Diag.add('mpv [${l.prefix}] ${l.level}: ${l.text.trim()}');
    }));
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
      final rot = await mp4Rotation(widget.file.path);
      if (!mounted) return;
      final turned = rot == 90 || rot == 270;
      // кадр приходит неповёрнутым: размер окна вывода — по нему; RDP: не больше 1280×720
      final s = turned ? fitSize(widget.videoH, widget.videoW, 1280, 720) : fitSize(widget.videoW, widget.videoH, 1280, 720);
      setState(() {
        _rot = rot ?? 0;
        _controller = _videoController(_player, s.w, s.h);
      });
      await _player.open(Media(Uri.file(widget.file.path).toString()), play: false);
      final n = _player.platform;
      if (rot == null && n is NativePlayer) {
        final r = await _mpvRotation(n);
        if (mounted && r != 0) setState(() => _rot = r);
      }
      if (mounted && widget.autoplay) await _player.play();
    } catch (e, st) {
      Diag.err('Воспроизведение видео (mpv)', e, st);
      if (mounted) widget.onFailed();
    }
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    if (_full) unawaited(windowManager.setFullScreen(false).catchError((_) {}));
    _player.dispose().whenComplete(() {
      _busy(_play, false);
      Diag.mark('видео (mpv): воспроизведение — готово');
    });
    super.dispose();
  }

  bool _full = false;
  Future<void> _toggleFull() async {
    try {
      _full = !_full;
      await windowManager.setFullScreen(_full);
      if (mounted) setState(() {});
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final c = _controller;
    if (c == null) return const Center(child: CircularProgressIndicator());
    final picture = RotatedBox(
      quarterTurns: _rot ~/ 90,
      child: Video(controller: c, controls: NoVideoControls, fill: Colors.black),
    );
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.space): _player.playOrPause,
        const SingleActivator(LogicalKeyboardKey.arrowRight): () => _player.seek(_player.state.position + const Duration(seconds: 5)),
        const SingleActivator(LogicalKeyboardKey.arrowLeft): () => _player.seek(_player.state.position - const Duration(seconds: 5)),
        const SingleActivator(LogicalKeyboardKey.escape): () => _full ? _toggleFull() : null,
      },
      child: Focus(
        autofocus: true,
        child: ColoredBox(
          color: Colors.black,
          child: Column(children: [
            Expanded(
              child: GestureDetector(
                onTap: _player.playOrPause,
                onDoubleTap: _toggleFull,
                child: picture,
              ),
            ),
            _MpvBar(player: _player, full: _full, onFull: _toggleFull),
          ]),
        ),
      ),
    );
  }
}

String _t(Duration d) {
  final s = d.inSeconds;
  String two(int v) => v.toString().padLeft(2, '0');
  return s >= 3600 ? '${s ~/ 3600}:${two(s ~/ 60 % 60)}:${two(s % 60)}' : '${two(s ~/ 60)}:${two(s % 60)}';
}

/// Полоса управления: пауза, перемотка, время, звук, полный экран.
class _MpvBar extends StatefulWidget {
  final Player player;
  final bool full;
  final VoidCallback onFull;
  const _MpvBar({required this.player, required this.full, required this.onFull});
  @override
  State<_MpvBar> createState() => _MpvBarState();
}

class _MpvBarState extends State<_MpvBar> {
  final _subs = <StreamSubscription>[];
  double? _drag; // перетаскивание ползунка, доля 0..1

  @override
  void initState() {
    super.initState();
    final st = widget.player.stream;
    for (final s in <Stream>[st.playing, st.position, st.duration, st.volume, st.completed]) {
      _subs.add(s.listen((_) {
        if (mounted) setState(() {});
      }));
    }
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.player;
    final st = p.state;
    final dur = st.duration;
    final pos = st.position > dur ? dur : st.position;
    final frac = _drag ?? (dur.inMilliseconds > 0 ? pos.inMilliseconds / dur.inMilliseconds : 0.0);
    final muted = st.volume <= 0;
    const white = Colors.white;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 6),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            trackHeight: 3,
            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
            overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
            activeTrackColor: white,
            inactiveTrackColor: Colors.white24,
            thumbColor: white,
          ),
          child: Slider(
            value: frac.clamp(0.0, 1.0).toDouble(),
            onChanged: dur.inMilliseconds > 0 ? (v) => setState(() => _drag = v) : null,
            onChangeEnd: (v) async {
              await p.seek(Duration(milliseconds: (v * dur.inMilliseconds).round()));
              if (mounted) setState(() => _drag = null);
            },
          ),
        ),
        Row(children: [
          IconButton(
            color: white,
            tooltip: st.playing ? 'Пауза' : 'Смотреть',
            icon: Icon(st.playing ? Icons.pause : Icons.play_arrow),
            onPressed: () async {
              if (st.completed) await p.seek(Duration.zero);
              await p.playOrPause();
            },
          ),
          IconButton(
            color: white,
            tooltip: muted ? 'Включить звук' : 'Выключить звук',
            icon: Icon(muted ? Icons.volume_off : Icons.volume_up),
            onPressed: () => p.setVolume(muted ? 100 : 0),
          ),
          const SizedBox(width: 8),
          Text('${_t(_drag != null ? Duration(milliseconds: (_drag! * dur.inMilliseconds).round()) : pos)} / ${_t(dur)}',
              style: const TextStyle(color: white, fontFeatures: [FontFeature.tabularFigures()])),
          const Spacer(),
          IconButton(
            color: white,
            tooltip: widget.full ? 'Выйти из полноэкранного режима' : 'Во весь экран',
            icon: Icon(widget.full ? Icons.fullscreen_exit : Icons.fullscreen),
            onPressed: widget.onFull,
          ),
        ]),
      ]),
    );
  }
}
