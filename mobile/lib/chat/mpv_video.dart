// Видео на Windows Server и в RDP-сеансе — собственным проигрывателем (mpv + FFmpeg, пакет media_kit),
// как в Telegram Desktop. Видеомодуль Windows (Media Foundation) на сервере часто неполный и ронял Ласточку,
// поэтому там он не используется вовсе: и кадр-превью, и воспроизведение — через mpv.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../system/diag.dart';
import '../system/perf.dart' show windowsMediaSafe;

/// Видео через mpv: Windows Server или RDP-сеанс.
final bool useMpv = Platform.isWindows && !windowsMediaSafe;

void initMpv() {
  if (!useMpv) return;
  try {
    MediaKit.ensureInitialized();
  } catch (e) {
    Diag.err('Проигрыватель видео (mpv)', e);
  }
}

/// Первый кадр видео (JPEG), размеры и длительность — через mpv. null — не получилось.
Future<({Uint8List jpeg, int w, int h, int durationMs})?> mpvFrame(String path) async {
  Player? player;
  try {
    player = Player(configuration: const PlayerConfiguration(title: 'Ласточка', logLevel: MPVLogLevel.error));
    // без видеокарты: на RDP-сервере её нет, кадр рисуется процессором
    final controller = VideoController(player, configuration: const VideoControllerConfiguration(enableHardwareAcceleration: false));
    await player.setVolume(0);
    await player.open(Media(Uri.file(path).toString()), play: false);
    await controller.waitUntilFirstFrameRendered.timeout(const Duration(seconds: 15));
    final jpeg = await player.screenshot(format: 'image/jpeg').timeout(const Duration(seconds: 10));
    if (jpeg == null || jpeg.isEmpty) return null;
    final w = player.state.width ?? 0, h = player.state.height ?? 0;
    return (jpeg: jpeg, w: w, h: h, durationMs: player.state.duration.inMilliseconds);
  } catch (e, st) {
    Diag.err('Кадр из видео (mpv)', e, st);
    return null;
  } finally {
    try {
      await player?.dispose();
    } catch (_) {}
  }
}

/// Проигрыватель внутри Ласточки (mpv): пауза, перемотка, громкость, полный экран — как в Telegram.
class MpvVideoView extends StatefulWidget {
  final File file;
  final bool autoplay;
  final VoidCallback onFailed;
  const MpvVideoView({super.key, required this.file, required this.onFailed, this.autoplay = true});
  @override
  State<MpvVideoView> createState() => _MpvVideoViewState();
}

class _MpvVideoViewState extends State<MpvVideoView> {
  late final Player _player = Player(configuration: const PlayerConfiguration(title: 'Ласточка', logLevel: MPVLogLevel.error));
  late final VideoController _controller =
      VideoController(_player, configuration: const VideoControllerConfiguration(enableHardwareAcceleration: false));
  StreamSubscription? _err;

  @override
  void initState() {
    super.initState();
    _err = _player.stream.error.listen((e) {
      Diag.add('Воспроизведение видео (mpv): $e');
    });
    _player.open(Media(Uri.file(widget.file.path).toString()), play: widget.autoplay).catchError((Object e) {
      Diag.err('Воспроизведение видео (mpv)', e);
      if (mounted) widget.onFailed();
    });
  }

  @override
  void dispose() {
    _err?.cancel();
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Video(
        controller: _controller,
        controls: MaterialDesktopVideoControls,
        fill: Colors.black,
      );
}
