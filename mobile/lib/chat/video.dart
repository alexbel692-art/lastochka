// Видео: «кружки» (короткие видеосообщения с фронтальной камеры, как в Telegram) и просмотр видео
// внутри Ласточки. Расшифрованный файл лежит во внутренней папке и удаляется при следующем запуске.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:matrix/matrix.dart';
import 'package:path/path.dart' as p;
import 'package:video_player/video_player.dart';

import '../system/privacy.dart';
import 'autodelete.dart';
import 'voice.dart' show fmtDur;

const roundKey = 'ru.lastochka.round';
final bool videoSupported = Platform.isAndroid || Platform.isIOS || Platform.isMacOS;
final bool canRecordRound = Platform.isAndroid || Platform.isIOS;

bool isRound(Event e) => e.messageType == MessageTypes.Video && e.content[roundKey] == true;

/// Записать и отправить «кружок».
Future<String?> recordRound(Room room, {Event? inReplyTo}) async {
  final x = await ImagePicker().pickVideo(source: ImageSource.camera, preferredCameraDevice: CameraDevice.front, maxDuration: const Duration(seconds: 60));
  if (x == null) return null;
  final size = await x.length();
  if (size > 60 * 1024 * 1024) return 'Видео слишком большое';
  int? durationMs;
  try {
    final c = VideoPlayerController.file(File(x.path));
    await c.initialize();
    durationMs = c.value.duration.inMilliseconds;
    await c.dispose();
  } catch (_) {}
  await room.sendFileEvent(
    MatrixVideoFile(bytes: await x.readAsBytes(), name: 'Видеосообщение.mp4', mimeType: 'video/mp4', duration: durationMs),
    inReplyTo: inReplyTo,
    extraContent: {'body': 'Видеосообщение', roundKey: true, ...ttlExtra(room)},
  );
  try {
    await File(x.path).delete();
  } catch (_) {}
  return null;
}

final Map<String, Future<File?>> _files = {};

Future<File?> _decrypted(Event e) => _files.putIfAbsent(e.eventId, () async {
      try {
        final f = await e.downloadAndDecryptAttachment();
        final path = p.join((await privateTemp()).path, 'video_${e.eventId.hashCode.abs()}.mp4');
        return File(path)..writeAsBytesSync(f.bytes, flush: true);
      } catch (_) {
        _files.remove(e.eventId);
        return null;
      }
    });

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
        if (!mounted) return c.dispose();
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
