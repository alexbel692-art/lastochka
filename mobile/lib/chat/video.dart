// Видео: «кружки» (короткие видеосообщения с фронтальной камеры, как в Telegram) и просмотр видео
// внутри Ласточки. Расшифрованный файл лежит во внутренней папке и удаляется при следующем запуске.
import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:matrix/matrix.dart';
import 'package:path/path.dart' as p;
import 'package:video_player/video_player.dart';

import '../system/lru.dart';
import '../system/media_clean.dart';
import '../system/privacy.dart';
import 'autodelete.dart';
import 'voice.dart' show fmtDur;

const roundKey = 'ru.lastochka.round';
final bool videoSupported = Platform.isAndroid || Platform.isIOS || Platform.isMacOS;
final bool canRecordRound = Platform.isAndroid || Platform.isIOS;

const _system = MethodChannel('lastochka/system');

/// Кадр-превью видео (JPEG, без сведений из исходного файла) и размеры самого видео.
class VideoFrame {
  final Uint8List jpeg;
  final int w, h, videoW, videoH, durationMs;
  const VideoFrame(this.jpeg, this.w, this.h, this.videoW, this.videoH, this.durationMs);
}

const _frames = MethodChannel('lastochka/video_frame');

/// Где умеем доставать кадр из видео: Android — системой, iPhone и Mac — AVFoundation,
/// Windows — Media Foundation (модуль packages/video_frame).
final bool frameSupported = Platform.isAndroid || Platform.isIOS || Platform.isMacOS || Platform.isWindows;

/// Первый кадр видеофайла (JPEG до 480 точек) и размеры самого видео.
Future<VideoFrame?> videoFrame(String path) async {
  if (!frameSupported) return null;
  try {
    final args = {'path': path, 'max': 480};
    final r = await (Platform.isAndroid ? _system.invokeMapMethod<String, Object?>('videoFrame', args) : _frames.invokeMapMethod<String, Object?>('frame', args))
        .timeout(const Duration(seconds: 20));
    if (r == null) return null;
    int n(String k) => (r[k] as num?)?.toInt() ?? 0;
    var jpeg = r['jpeg'];
    final rgba = r['rgba'];
    if (jpeg is! Uint8List && rgba is Uint8List) {
      // Windows отдаёт пиксели — сжимаем в JPEG здесь (в отдельном потоке)
      jpeg = await compute(_toJpeg, (rgba, n('w'), n('h'), n('rot')));
    }
    if (jpeg is! Uint8List || jpeg.isEmpty) return null;
    final turned = n('rot') == 90 || n('rot') == 270;
    return VideoFrame(jpeg, turned ? n('h') : n('w'), turned ? n('w') : n('h'), n('vw'), n('vh'), n('duration'));
  } catch (_) {
    return null;
  }
}

Uint8List? _toJpeg((Uint8List, int, int, int) a) {
  final (bytes, w, h, rot) = a;
  if (w <= 0 || h <= 0 || bytes.length < w * h * 4) return null;
  var im = img.Image.fromBytes(width: w, height: h, bytes: bytes.buffer, bytesOffset: bytes.offsetInBytes, numChannels: 4);
  if (rot != 0) im = img.copyRotate(im, angle: rot);
  return img.encodeJpg(im, quality: 82);
}

bool isRound(Event e) => e.messageType == MessageTypes.Video && e.content[roundKey] == true;

Future<int?> _durationOf(String path) async {
  if (!videoSupported) return null;
  try {
    final c = VideoPlayerController.file(File(path));
    await c.initialize();
    final d = c.value.duration.inMilliseconds;
    await c.dispose();
    return d;
  } catch (_) {
    return null;
  }
}

/// Записать и отправить «кружок».
Future<String?> recordRound(Room room, {Event? inReplyTo}) async {
  final x = await ImagePicker().pickVideo(source: ImageSource.camera, preferredCameraDevice: CameraDevice.front, maxDuration: const Duration(seconds: 60));
  if (x == null) return null;
  try {
    return await sendVideoFile(room, x.path, x.name, inReplyTo: inReplyTo, round: true);
  } finally {
    try {
      await File(x.path).delete();
    } catch (_) {}
  }
}

/// Выбрать видео из галереи и отправить (без места съёмки и прочих сведений).
Future<String?> pickAndSendVideo(Room room, {Event? inReplyTo}) async {
  final x = await ImagePicker().pickVideo(source: ImageSource.gallery);
  if (x == null) return null;
  try {
    return await sendVideoFile(room, x.path, x.name, inReplyTo: inReplyTo);
  } finally {
    // копия видео, которую сделал выбор файла, не должна оставаться в кэше
    if (Platform.isAndroid || Platform.isIOS) {
      try {
        await File(x.path).delete();
      } catch (_) {}
    }
  }
}

// ---------- сжатие ----------

/// Где видео сжимается перед отправкой: Android (Media3), iPhone и Mac (AVFoundation).
final bool compressSupported = Platform.isAndroid || Platform.isIOS || Platform.isMacOS;

/// Видео больше этого размера сжимаются (как в Telegram: до 720p, кружки — до 480p).
const compressFrom = 12 * 1024 * 1024;
const maxVideoSend = 100 * 1024 * 1024;

/// Ход сжатия (0…1) для полоски над полем ввода; null — сжатия нет.
final compressProgress = ValueNotifier<double?>(null);

Future<String?> compressVideo(String src, {bool round = false}) async {
  if (!compressSupported) return null;
  final ch = Platform.isAndroid ? _system : _frames;
  final dst = p.join((await privateTemp()).path, 'send_${DateTime.now().microsecondsSinceEpoch}.mp4');
  compressProgress.value = 0;
  final t = Timer.periodic(const Duration(milliseconds: 400), (_) async {
    try {
      final v = await ch.invokeMethod<int>('compressProgress');
      if (v != null && v >= 0 && compressProgress.value != null) compressProgress.value = v / 100;
    } catch (_) {}
  });
  try {
    final ok = await ch
        .invokeMethod<bool>(Platform.isAndroid ? 'compressVideo' : 'compress', {'src': src, 'dst': dst, 'short': round ? 480 : 720, 'bitrate': round ? 1200000 : 2500000})
        .timeout(const Duration(minutes: 20));
    if (ok == true && File(dst).existsSync() && File(dst).lengthSync() > 0) return dst;
  } catch (_) {}
  try {
    File(dst).deleteSync();
  } catch (_) {}
  return null;
}

/// Отправить видео с диска: при необходимости сжать, убрать скрытые сведения, приложить превью.
/// Исходный файл не трогается. Возвращает текст ошибки или null.
Future<String?> sendVideoFile(Room room, String path, String name, {Event? inReplyTo, bool round = false, Map<String, Object?> extra = const {}}) async {
  var size = await File(path).length();
  if (size > (compressSupported ? 4096 : 100) * 1024 * 1024) return 'Видео слишком большое — отправьте его файлом';
  String? tmp;
  try {
    if (compressSupported && size > compressFrom) {
      try {
        final c = await compressVideo(path, round: round);
        if (c != null) {
          final cs = await File(c).length();
          if (cs < size) {
            tmp = c;
            path = c;
            size = cs;
          } else {
            await File(c).delete();
          }
        }
      } finally {
        compressProgress.value = null;
      }
    }
    if (size > maxVideoSend) return 'Видео больше 100 МБ даже после сжатия — отправьте его файлом';
    final clean = await cleanVideo(await File(path).readAsBytes());
    if (clean == null) return 'Не удалось убрать из видео скрытые сведения (место съёмки и др.) — видео не отправлено. Можно отправить его как файл';
    final mov = tmp == null && name.toLowerCase().endsWith('.mov');
    final base = name.contains('.') ? name.substring(0, name.lastIndexOf('.')) : 'Видео';
    // превью-кадр, чтобы у собеседника видео выглядело как в Telegram, а не как файл
    final frame = await videoFrame(path);
    await room.sendFileEvent(
      MatrixVideoFile(
        bytes: clean,
        name: round ? 'Видеосообщение.mp4' : '$base.${mov ? 'mov' : 'mp4'}',
        mimeType: mov ? 'video/quicktime' : 'video/mp4',
        width: frame != null && frame.videoW > 0 ? frame.videoW : null,
        height: frame != null && frame.videoH > 0 ? frame.videoH : null,
        duration: frame != null && frame.durationMs > 0 ? frame.durationMs : await _durationOf(path),
      ),
      thumbnail: frame == null ? null : MatrixImageFile(bytes: frame.jpeg, name: 'thumbnail.jpg', mimeType: 'image/jpeg', width: frame.w, height: frame.h),
      inReplyTo: inReplyTo,
      extraContent: {if (round) 'body': 'Видеосообщение', if (round) roundKey: true, ...extra, ...ttlExtra(room)},
    );
    return null;
  } finally {
    if (tmp != null) {
      try {
        await File(tmp).delete();
      } catch (_) {}
    }
  }
}

// Превью видео в ленте: уменьшенная копия от отправителя, а если её нет (Element, мосты) —
// небольшое видео скачивается и кадр берётся из него, как в Telegram.
final _previews = Lru<String, Future<Uint8List?>>(60)..register();
const _autoFrameLimit = 30 * 1024 * 1024;

Future<Uint8List?> _preview(Event e) => _previews.putIfAbsent(e.eventId, () async {
      if (e.hasThumbnail) {
        try {
          return (await e.downloadAndDecryptAttachment(getThumbnail: true)).bytes;
        } catch (_) {}
      }
      final size = (e.content.tryGetMap<String, Object?>('info')?['size'] as num?)?.toInt() ?? 0;
      if (!frameSupported || size <= 0 || size > _autoFrameLimit) return null;
      final f = await _decrypted(e);
      if (f == null) return null;
      return (await videoFrame(f.path))?.jpeg;
    });

String _mb(int b) => b >= 1048576 ? '${(b / 1048576).toStringAsFixed(1)} МБ' : '${max(1, b ~/ 1024)} КБ';

/// Видео в ленте: кадр, кнопка воспроизведения, длительность и размер.
class VideoPreview extends StatelessWidget {
  final Event event;
  final double maxWidth;
  final VoidCallback onOpen;
  /// В альбоме: точная высота плитки и без скругления (скругляется весь альбом).
  final double? height;
  final double radius;
  const VideoPreview({super.key, required this.event, required this.maxWidth, required this.onOpen, this.height, this.radius = 13});

  @override
  Widget build(BuildContext context) {
    final info = event.content.tryGetMap<String, Object?>('info');
    final w = (info?['w'] as num?)?.toDouble();
    final h = (info?['h'] as num?)?.toDouble();
    final dur = (info?['duration'] as num?)?.toInt();
    final size = (info?['size'] as num?)?.toInt();
    final thumb = info?.tryGetMap<String, Object?>('thumbnail_info');
    final tw = (thumb?['w'] as num?)?.toDouble(), th = (thumb?['h'] as num?)?.toDouble();
    final ratio = (w != null && h != null && w > 0 && h > 0)
        ? w / h
        : (tw != null && th != null && tw > 0 && th > 0)
            ? tw / th
            : 16 / 9;
    final decodeW = (maxWidth * MediaQuery.devicePixelRatioOf(context)).ceil().clamp(64, 1200);
    final chip = [if (dur != null && dur > 0) fmtDur(dur), if (size != null && size > 0) _mb(size)].join(' · ');
    Widget box(Widget child) => height != null
        ? SizedBox(width: maxWidth, height: height, child: child)
        : SizedBox(width: maxWidth, child: AspectRatio(aspectRatio: ratio.clamp(0.6, 1.9), child: child));
    final small = height != null && height! < 120;
    return GestureDetector(
      onTap: onOpen,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: box(
            Stack(fit: StackFit.expand, children: [
              const DecoratedBox(
                decoration: BoxDecoration(gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [Color(0xFF2A3440), Color(0xFF151A20)])),
              ),
              FutureBuilder<Uint8List?>(
                future: _preview(event),
                builder: (_, s) => s.data == null
                    ? const SizedBox.shrink()
                    : Image.memory(s.data!, fit: BoxFit.cover, gaplessPlayback: true, cacheWidth: decodeW, errorBuilder: (_, __, ___) => const SizedBox.shrink()),
              ),
              Center(
                child: Container(
                  width: small ? 34 : 54,
                  height: small ? 34 : 54,
                  decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.45), shape: BoxShape.circle),
                  child: Icon(Icons.play_arrow_rounded, color: Colors.white, size: small ? 24 : 38),
                ),
              ),
              if (chip.isNotEmpty && !small)
                Positioned(
                  left: 8,
                  top: 8,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                    decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.45), borderRadius: BorderRadius.circular(10)),
                    child: Text(chip, style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w500)),
                  ),
                ),
            ]),
        ),
      ),
    );
  }
}

/// «Кружок» в ленте: нажатие — воспроизвести со звуком, ещё нажатие — пауза.
class RoundVideo extends StatefulWidget {
  final Event event;
  final void Function() openExternally;
  const RoundVideo({super.key, required this.event, required this.openExternally});
  @override
  State<RoundVideo> createState() => _RoundVideoState();
}

class _RoundVideoState extends State<RoundVideo> {
  VideoPlayerController? _c;
  bool _loading = false, _failed = false;

  @override
  void dispose() {
    _c?.dispose();
    super.dispose();
  }

  Future<void> _toggle() async {
    if (!videoSupported) return widget.openExternally();
    final c = _c;
    if (c != null) {
      c.value.isPlaying ? await c.pause() : await c.play();
      return;
    }
    setState(() => _loading = true);
    final f = await _decrypted(widget.event);
    if (!mounted) return;
    if (f == null) {
      return setState(() {
        _failed = true;
        _loading = false;
      });
    }
    final nc = VideoPlayerController.file(f);
    try {
      await nc.initialize();
      nc.addListener(() {
        if (mounted) setState(() {});
        if (nc.value.isCompleted) nc.seekTo(Duration.zero);
      });
      setState(() {
        _c = nc;
        _loading = false;
      });
      await nc.play();
    } catch (_) {
      await nc.dispose();
      setState(() {
        _loading = false;
        _failed = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = _c;
    final info = widget.event.content.tryGetMap<String, Object?>('info');
    final dur = (info?['duration'] as num?)?.toInt();
    final playing = c?.value.isPlaying == true;
    final progress = c == null || c.value.duration.inMilliseconds == 0 ? 0.0 : c.value.position.inMilliseconds / c.value.duration.inMilliseconds;
    const size = 220.0;
    return GestureDetector(
      onTap: _toggle,
      child: SizedBox(
        width: size,
        height: size,
        child: Stack(alignment: Alignment.center, children: [
          ClipOval(
            child: Container(
              width: size,
              height: size,
              color: Colors.black26,
              child: c != null && c.value.isInitialized
                  ? FittedBox(fit: BoxFit.cover, child: SizedBox(width: c.value.size.width, height: c.value.size.height, child: VideoPlayer(c)))
                  : null,
            ),
          ),
          SizedBox(width: size, height: size, child: CircularProgressIndicator(value: c == null ? 0 : progress, strokeWidth: 3, color: Colors.white70)),
          if (_loading) const CircularProgressIndicator(color: Colors.white),
          if (!_loading && !playing) Icon(_failed ? Icons.error_outline : Icons.play_arrow_rounded, size: 56, color: Colors.white),
          if (dur != null && !playing)
            Positioned(
              bottom: 14,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                decoration: BoxDecoration(color: Colors.black45, borderRadius: BorderRadius.circular(8)),
                child: Text(fmtDur(dur), style: const TextStyle(color: Colors.white, fontSize: 12)),
              ),
            ),
        ]),
      ),
    );
  }
}

/// Полноэкранный просмотр обычного видео.
Future<void> openVideo(BuildContext context, Event e, void Function() openExternally) async {
  if (!videoSupported) return openExternally();
  await Navigator.of(context).push(MaterialPageRoute(builder: (_) => _VideoPage(event: e)));
}

class _VideoPage extends StatefulWidget {
  final Event event;
  const _VideoPage({required this.event});
  @override
  State<_VideoPage> createState() => _VideoPageState();
}

class _VideoPageState extends State<_VideoPage> {
  VideoPlayerController? _c;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _decrypted(widget.event).then((f) async {
      if (!mounted) return;
      if (f == null) return setState(() => _failed = true);
      final c = VideoPlayerController.file(f);
      try {
        await c.initialize();
        if (!mounted) {
          await c.dispose();
          return;
        }
        c.addListener(() => mounted ? setState(() {}) : null);
        setState(() => _c = c);
        await c.play();
      } catch (_) {
        await c.dispose();
        if (mounted) setState(() => _failed = true);
      }
    });
  }

  @override
  void dispose() {
    _c?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = _c;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(backgroundColor: Colors.black, foregroundColor: Colors.white),
      body: Center(
        child: _failed
            ? const Text('Не удалось открыть видео', style: TextStyle(color: Colors.white))
            : c == null
                ? const CircularProgressIndicator()
                : GestureDetector(
                    onTap: () => c.value.isPlaying ? c.pause() : c.play(),
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      Flexible(child: AspectRatio(aspectRatio: c.value.aspectRatio, child: VideoPlayer(c))),
                      VideoProgressIndicator(c, allowScrubbing: true, padding: const EdgeInsets.all(12)),
                      Text('${fmtDur(c.value.position.inMilliseconds)} / ${fmtDur(c.value.duration.inMilliseconds)}', style: const TextStyle(color: Colors.white70)),
                      const SizedBox(height: 12),
                    ]),
                  ),
      ),
    );
  }
}
