// Просмотр фото и видео с листанием к соседним (свайп, стрелки на клавиатуре), как в Telegram.
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:matrix/matrix.dart';

import '../system/lru.dart';
import 'forward.dart' show forwardEvents;
import 'save_media.dart';
import 'video.dart';

final _full = Lru<String, Future<Uint8List?>>(12)..register();

Future<Uint8List?> _load(Event e) => _full.putIfAbsent(e.eventId, () async {
      try {
        return (await e.downloadAndDecryptAttachment()).bytes;
      } catch (_) {
        _full.remove(e.eventId);
        return null;
      }
    });

bool isViewableMedia(Event e) => !e.redacted && (e.messageType == MessageTypes.Image || (e.messageType == MessageTypes.Video && !isRound(e)));

/// Открыть просмотр: [items] — по порядку (старые слева), [initial] — с какого начать.
Future<void> openMediaViewer(BuildContext context, List<Event> items, Event initial, {required void Function(Event) openExternally}) {
  final i = items.indexWhere((e) => e.eventId == initial.eventId);
  // поверх всего окна (и из боковой панели профиля на компьютере)
  return Navigator.of(context, rootNavigator: true).push(MaterialPageRoute(
    builder: (_) => _MediaViewer(items: i < 0 ? [initial] : items, initial: i < 0 ? 0 : i, openExternally: openExternally),
  ));
}

class _MediaViewer extends StatefulWidget {
  final List<Event> items;
  final int initial;
  final void Function(Event) openExternally;
  const _MediaViewer({required this.items, required this.initial, required this.openExternally});
  @override
  State<_MediaViewer> createState() => _MediaViewerState();
}

class _MediaViewerState extends State<_MediaViewer> {
  late final _pages = PageController(initialPage: widget.initial);
  late int _i = widget.initial;

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  void _go(int d) {
    final n = (_i + d).clamp(0, widget.items.length - 1);
    if (n != _i) _pages.animateToPage(n, duration: const Duration(milliseconds: 220), curve: Curves.easeOut);
  }

  @override
  Widget build(BuildContext context) {
    final e = widget.items[_i];
    final who = e.senderFromMemoryOrFallback.calcDisplayname();
    final w = MediaQuery.sizeOf(context).width * MediaQuery.devicePixelRatioOf(context);
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.arrowLeft): () => _go(-1),
        const SingleActivator(LogicalKeyboardKey.arrowRight): () => _go(1),
        const SingleActivator(LogicalKeyboardKey.escape): () => Navigator.maybePop(context),
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          backgroundColor: Colors.black,
          appBar: AppBar(
            backgroundColor: Colors.black,
            foregroundColor: Colors.white,
            actions: [
              IconButton(tooltip: saveMediaLabel, icon: const Icon(Icons.download_rounded), onPressed: () => saveMedia(context, widget.items[_i])),
              IconButton(tooltip: 'Переслать', icon: const Icon(Icons.shortcut_rounded), onPressed: () => forwardEvents(context, [widget.items[_i]], null)),
              const SizedBox(width: 4),
            ],
            title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(widget.items.length > 1 ? '${_i + 1} из ${widget.items.length}' : who, style: const TextStyle(fontSize: 17)),
              Text('${widget.items.length > 1 ? '$who · ' : ''}${DateFormat('d MMM, HH:mm', 'ru').format(e.originServerTs)}',
                  style: const TextStyle(fontSize: 12.5, color: Colors.white70)),
            ]),
          ),
          body: Stack(children: [
            PageView.builder(
              controller: _pages,
              itemCount: widget.items.length,
              onPageChanged: (i) => setState(() => _i = i),
              itemBuilder: (_, i) {
                final m = widget.items[i];
                if (m.messageType == MessageTypes.Video) {
                  return Center(
                    child: VideoPreview(
                      event: m,
                      maxWidth: MediaQuery.sizeOf(context).width.clamp(200, 720).toDouble(),
                      onOpen: () => openVideo(context, m, () => widget.openExternally(m)),
                    ),
                  );
                }
                return FutureBuilder<Uint8List?>(
                  future: _load(m),
                  builder: (_, s) => s.data == null
                      ? Center(child: s.connectionState == ConnectionState.done ? const Icon(Icons.broken_image_outlined, color: Colors.white) : const CircularProgressIndicator())
                      : InteractiveViewer(
                          maxScale: 6,
                          child: Center(child: Image.memory(s.data!, fit: BoxFit.contain, cacheWidth: (w * 2).ceil().clamp(512, 4096), gaplessPlayback: true)),
                        ),
                );
              },
            ),
            // стрелки по бокам — для мыши
            if (_i > 0)
              Positioned(left: 8, top: 0, bottom: 0, child: Center(child: _arrow(Icons.chevron_left_rounded, () => _go(-1)))),
            if (_i < widget.items.length - 1)
              Positioned(right: 8, top: 0, bottom: 0, child: Center(child: _arrow(Icons.chevron_right_rounded, () => _go(1)))),
          ]),
        ),
      ),
    );
  }

  Widget _arrow(IconData i, VoidCallback f) => Material(
        color: Colors.black.withValues(alpha: 0.35),
        shape: const CircleBorder(),
        child: IconButton(icon: Icon(i, color: Colors.white, size: 30), onPressed: f),
      );
}
