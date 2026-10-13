// «Медиа, файлы и ссылки» в профиле чата, как в Telegram: всё, что присылали, на трёх вкладках.
// История подгружается с сервера и расшифровывается на устройстве.
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:matrix/matrix.dart';

import '../chat/formatting.dart';
import '../chat/media_viewer.dart';
import '../chat/video.dart';
import '../chat/voice.dart' show VoiceMessage;
import '../widgets/avatar.dart';
import '../system/diag.dart';
import '../system/image_guard.dart';
import '../system/lru.dart';
import '../system/media_policy.dart';
import 'chat.dart' show openAttachment;

final _thumbs = Lru<String, Future<Uint8List?>>(150)..register();
final _url = RegExp(r'''(?:https?://|www\.)[^\s<>"']+[^\s<>"'.,;:!?)\]}]''', caseSensitive: false);

/// Разделы: 0 — медиа, 1 — файлы, 2 — ссылки, 3 — голосовые.
class RoomMediaPage extends StatefulWidget {
  final Room room;
  final int initialTab;
  const RoomMediaPage({super.key, required this.room, this.initialTab = 0});
  @override
  State<RoomMediaPage> createState() => _RoomMediaPageState();
}

class _RoomMediaPageState extends State<RoomMediaPage> {
  Timeline? _tl;
  bool _loading = true;
  List<Event> _media = [], _files = [], _voice = [];
  List<(Event, String)> _links = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _tl?.cancelSubscriptions();
    super.dispose();
  }

  void _collect() {
    final tl = _tl;
    if (tl == null) return;
    final media = <Event>[], files = <Event>[], voice = <Event>[], links = <(Event, String)>[];
    for (final e in tl.events) {
      if (e.redacted || e.type != EventTypes.Message) continue;
      final d = e.getDisplayEvent(tl);
      if (isViewableMedia(d)) {
        media.add(d);
      } else if (d.messageType == MessageTypes.Audio) {
        voice.add(d); // голосовые и аудиозаписи
      } else if (d.messageType == MessageTypes.File) {
        files.add(d);
      } else if (d.messageType == MessageTypes.Text || d.messageType == MessageTypes.Notice) {
        for (final m in _url.allMatches(d.body)) {
          links.add((d, m[0]!));
        }
      }
    }
    setState(() {
      _media = media;
      _files = files;
      _voice = voice;
      _links = links;
    });
  }

  Future<void> _load() async {
    try {
      final tl = await widget.room.getTimeline(onUpdate: () {
        if (mounted) _collect();
      });
      _tl = tl;
      _collect();
      // подгружаем историю порциями (до ~3000 сообщений), чтобы показать и давнее
      for (var i = 0; i < 30 && tl.canRequestHistory && mounted; i++) {
        await tl.requestHistory(historyCount: 100);
        if (mounted) _collect();
      }
    } catch (e) {
      Diag.err('Медиа чата', e);
    }
    if (mounted) setState(() => _loading = false);
  }

  void _toast(String s) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s)));

  @override
  Widget build(BuildContext context) {
    final hint = Theme.of(context).hintColor;
    return DefaultTabController(
      length: 4,
      initialIndex: widget.initialTab.clamp(0, 3),
      child: Scaffold(
        appBar: AppBar(
          title: Text(widget.room.getLocalizedDisplayname()),
          bottom: TabBar(isScrollable: true, tabAlignment: TabAlignment.center, tabs: [
            Tab(text: 'Медиа${_media.isEmpty ? '' : ' · ${_media.length}'}'),
            Tab(text: 'Файлы${_files.isEmpty ? '' : ' · ${_files.length}'}'),
            Tab(text: 'Ссылки${_links.isEmpty ? '' : ' · ${_links.length}'}'),
            Tab(text: 'Голосовые${_voice.isEmpty ? '' : ' · ${_voice.length}'}'),
          ]),
        ),
        body: Column(children: [
          if (_loading) const LinearProgressIndicator(minHeight: 2),
          Expanded(
            child: TabBarView(children: [
              // медиа: сетка миниатюр, новые сверху
              _media.isEmpty
                  ? _empty(_loading ? 'Ищем фото и видео…' : 'Фото и видео пока нет', hint)
                  : GridView.builder(
                      padding: const EdgeInsets.all(2),
                      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: 140, mainAxisSpacing: 2, crossAxisSpacing: 2),
                      itemCount: _media.length,
                      itemBuilder: (_, i) {
                        final e = _media[i];
                        return LayoutBuilder(builder: (_, c) {
                          void open() => openMediaViewer(context, _media.reversed.toList(), e,
                              openExternally: (m) => openAttachment(m, _toast, context: context));
                          if (e.messageType == MessageTypes.Video) {
                            return VideoPreview(event: e, maxWidth: c.maxWidth, height: c.maxHeight, radius: 0, onOpen: open);
                          }
                          // настройка «Показ фото и видео» (как в Element): миниатюра не загружается, по нажатию — откроется
                          if (!MediaPolicy.showIn(widget.room, senderId: e.senderId)) {
                            return GestureDetector(
                              onTap: open,
                              child: ColoredBox(
                                color: hint.withValues(alpha: 0.12),
                                child: Icon(Icons.visibility_off_outlined, color: hint),
                              ),
                            );
                          }
                          return GestureDetector(
                            onTap: open,
                            child: FutureBuilder<Uint8List?>(
                              future: _thumbs.putIfAbsent(e.eventId, () async {
                                try {
                                  return await guardImage((await e.downloadAndDecryptAttachment(getThumbnail: e.hasThumbnail)).bytes);
                                } catch (_) {
                                  return null;
                                }
                              }),
                              builder: (_, s) => s.data == null
                                  ? ColoredBox(color: hint.withValues(alpha: 0.12))
                                  : Image.memory(s.data!, fit: BoxFit.cover, gaplessPlayback: true, cacheWidth: 300),
                            ),
                          );
                        });
                      },
                    ),
              // файлы
              _files.isEmpty
                  ? _empty(_loading ? 'Ищем файлы…' : 'Файлов пока нет', hint)
                  : ListView.builder(
                      itemCount: _files.length,
                      itemBuilder: (_, i) {
                        final e = _files[i];
                        final size = (e.content.tryGetMap<String, Object?>('info')?['size'] as num?)?.toInt();
                        final name = e.content.tryGet<String>('filename') ?? e.body;
                        final ext = name.contains('.') ? name.split('.').last.toUpperCase() : 'ФАЙЛ';
                        return ListTile(
                          leading: Container(
                            width: 44,
                            height: 44,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(color: Theme.of(context).colorScheme.primary, borderRadius: BorderRadius.circular(12)),
                            child: Text(ext.length > 4 ? ext.substring(0, 4) : ext, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 11.5)),
                          ),
                          title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
                          subtitle: Text('${size == null ? '' : '${_size(size)} · '}${e.senderFromMemoryOrFallback.calcDisplayname()} · ${DateFormat('d MMM yyyy', 'ru').format(e.originServerTs)}',
                              maxLines: 1, overflow: TextOverflow.ellipsis),
                          onTap: () => openAttachment(e, _toast, context: context),
                        );
                      },
                    ),
              // ссылки
              _links.isEmpty
                  ? _empty(_loading ? 'Ищем ссылки…' : 'Ссылок пока нет', hint)
                  : ListView.builder(
                      itemCount: _links.length,
                      itemBuilder: (_, i) {
                        final (e, u) = _links[i];
                        final parts = linkParts(u);
                        return ListTile(
                          leading: CircleAvatar(backgroundColor: Theme.of(context).colorScheme.primary.withValues(alpha: 0.14), child: Icon(Icons.language, color: Theme.of(context).colorScheme.primary)),
                          title: Text(parts?.host ?? prettyUrl(u), maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
                          subtitle: Text('${prettyUrl(u)}\n${e.senderFromMemoryOrFallback.calcDisplayname()} · ${DateFormat('d MMM yyyy', 'ru').format(e.originServerTs)}',
                              maxLines: 2, overflow: TextOverflow.ellipsis),
                          onTap: () => openLink(context, u.toLowerCase().startsWith('www.') ? 'https://$u' : u),
                        );
                      },
                    ),
              // голосовые: слушать прямо здесь
              _voice.isEmpty
                  ? _empty(_loading ? 'Ищем голосовые…' : 'Голосовых пока нет', hint)
                  : ListView.separated(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      itemCount: _voice.length,
                      separatorBuilder: (_, __) => const Divider(height: 1, indent: 72),
                      itemBuilder: (_, i) {
                        final e = _voice[i];
                        final u = e.senderFromMemoryOrFallback;
                        return Padding(
                          padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                          child: Row(children: [
                            Avatar(mxc: u.avatarUrl, name: u.calcDisplayname(), size: 44),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                Text('${u.calcDisplayname()} · ${DateFormat('d MMM, HH:mm', 'ru').format(e.originServerTs)}', style: TextStyle(color: hint, fontSize: 12.5)),
                                const SizedBox(height: 4),
                                VoiceMessage(event: e, color: Theme.of(context).colorScheme.primary),
                              ]),
                            ),
                          ]),
                        );
                      },
                    ),
            ]),
          ),
        ]),
      ),
    );
  }

  Widget _empty(String t, Color hint) => Center(child: Text(t, style: TextStyle(color: hint)));
}

String _size(int b) => b >= 1048576 ? '${(b / 1048576).toStringAsFixed(1)} МБ' : '${(b / 1024).ceil()} КБ';
