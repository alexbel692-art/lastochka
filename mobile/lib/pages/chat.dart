import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:matrix/matrix.dart';

import '../main.dart';
import '../theme.dart';
import '../widgets/avatar.dart';
import 'chats.dart';

class ChatPage extends StatefulWidget {
  final Room room;
  const ChatPage({super.key, required this.room});
  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  Room get room => widget.room;
  Timeline? _tl;
  final _text = TextEditingController();
  final _scroll = ScrollController();
  Event? _replyTo;
  bool _loadingMore = false;

  @override
  void initState() {
    super.initState();
    _init();
    _scroll.addListener(() {
      if (_scroll.position.pixels > _scroll.position.maxScrollExtent - 600) _more();
    });
    _text.addListener(() => setState(() {}));
  }

  Future<void> _init() async {
    final tl = await room.getTimeline(onUpdate: () {
      if (mounted) setState(() {});
      _markRead();
    });
    if (!mounted) return tl.cancelSubscriptions();
    setState(() => _tl = tl);
    if (tl.events.length < 30) await _more();
    _markRead();
  }

  Future<void> _more() async {
    final tl = _tl;
    if (tl == null || _loadingMore || !tl.canRequestHistory) return;
    _loadingMore = true;
    try {
      await tl.requestHistory();
    } catch (_) {}
    _loadingMore = false;
  }

  void _markRead() {
    final last = _tl?.events.firstOrNull;
    if (last == null || room.notificationCount == 0 && room.fullyRead == last.eventId) return;
    room.setReadMarker(last.eventId, mRead: last.eventId).catchError((_) {});
  }

  @override
  void dispose() {
    _tl?.cancelSubscriptions();
    super.dispose();
  }

  Future<void> _send() async {
    final t = _text.text.trim();
    if (t.isEmpty) return;
    _text.clear();
    final reply = _replyTo;
    setState(() => _replyTo = null);
    await room.sendTextEvent(t, inReplyTo: reply);
  }

  Future<void> _sendPhoto() async {
    final x = await ImagePicker().pickImage(source: ImageSource.gallery, imageQuality: 85, maxWidth: 2560);
    if (x == null) return;
    final bytes = await x.readAsBytes();
    await room.sendFileEvent(MatrixImageFile(bytes: bytes, name: x.name));
  }

  // Видимые события: сообщения, стикеры, вход/выход участников, звонки.
  bool _visible(Event e) {
    if (e.relationshipType == RelationshipTypes.edit) return false;
    if (e.type == EventTypes.Message || e.type == EventTypes.Sticker || e.type == EventTypes.Encrypted) return true;
    if (e.type == EventTypes.CallInvite) return true;
    return memberText(e) != null;
  }

  void _actions(Event e) async {
    final mine = e.senderId == client.userID;
    final a = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (c) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(leading: const Icon(Icons.reply), title: const Text('Ответить'), onTap: () => Navigator.pop(c, 'reply')),
          if (e.messageType == MessageTypes.Text) ListTile(leading: const Icon(Icons.copy), title: const Text('Копировать'), onTap: () => Navigator.pop(c, 'copy')),
          if (mine && e.canRedact) ListTile(leading: const Icon(Icons.delete_outline, color: Colors.redAccent), title: const Text('Удалить', style: TextStyle(color: Colors.redAccent)), onTap: () => Navigator.pop(c, 'del')),
        ]),
      ),
    );
    switch (a) {
      case 'reply':
        setState(() => _replyTo = e);
      case 'copy':
        await Clipboard.setData(ClipboardData(text: e.getDisplayEvent(_tl!).body));
      case 'del':
        await e.redactEvent();
    }
  }

  @override
  Widget build(BuildContext context) {
    final name = room.getLocalizedDisplayname();
    final members = room.summary.mJoinedMemberCount ?? 0;
    final tl = _tl;
    final events = tl?.events.where(_visible).toList() ?? const <Event>[];
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: Row(children: [
          Avatar(mxc: room.avatar, name: name, size: 38),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
              Text(room.isDirectChat ? (room.encrypted ? 'защищённый чат' : 'личный чат') : '$members участн.',
                  style: TextStyle(fontSize: 13, color: Theme.of(context).hintColor)),
            ]),
          ),
        ]),
      ),
      body: Container(
        color: Bubbles.wall(context),
        child: Column(children: [
          Expanded(
            child: tl == null
                ? const Center(child: CircularProgressIndicator())
                : ListView.builder(
                    controller: _scroll,
                    reverse: true,
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                    itemCount: events.length,
                    itemBuilder: (_, i) {
                      final e = events[i];
                      final older = i + 1 < events.length ? events[i + 1] : null;
                      final newDay = older == null || !DateUtils.isSameDay(older.originServerTs, e.originServerTs);
                      final firstOfGroup = older == null || newDay || older.senderId != e.senderId || memberText(older) != null;
                      return Column(children: [
                        if (newDay) _DayChip(e.originServerTs),
                        memberText(e) != null
                            ? _ServiceChip(memberText(e)!)
                            : GestureDetector(
                                onLongPress: () => _actions(e),
                                child: _Bubble(event: e, timeline: tl, room: room, showName: firstOfGroup && !room.isDirectChat),
                              ),
                      ]);
                    },
                  ),
          ),
          _composer(context),
        ]),
      ),
    );
  }

  Widget _composer(BuildContext context) {
    final bg = Theme.of(context).scaffoldBackgroundColor;
    final accent = Theme.of(context).colorScheme.primary;
    return Material(
      color: bg,
      child: SafeArea(
        top: false,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          if (_replyTo != null)
            ListTile(
              dense: true,
              leading: Icon(Icons.reply, color: accent),
              title: Text(_replyTo!.senderFromMemoryOrFallback.calcDisplayname(), style: TextStyle(color: accent, fontWeight: FontWeight.w600)),
              subtitle: Text(_replyTo!.body, maxLines: 1, overflow: TextOverflow.ellipsis),
              trailing: IconButton(icon: const Icon(Icons.close), onPressed: () => setState(() => _replyTo = null)),
            ),
          Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
            IconButton(icon: const Icon(Icons.attach_file), onPressed: _sendPhoto),
            Expanded(
              child: TextField(
                controller: _text,
                minLines: 1,
                maxLines: 6,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(hintText: 'Сообщение', filled: false, border: InputBorder.none),
              ),
            ),
            IconButton(icon: Icon(Icons.send, color: _text.text.trim().isEmpty ? Theme.of(context).hintColor : accent), onPressed: _send),
          ]),
        ]),
      ),
    );
  }
}

class _DayChip extends StatelessWidget {
  final DateTime d;
  const _DayChip(this.d);
  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final s = DateUtils.isSameDay(d, now) ? 'Сегодня' : DateFormat(d.year == now.year ? 'd MMMM' : 'd MMMM y', 'ru').format(d);
    return _ServiceChip(s);
  }
}

class _ServiceChip extends StatelessWidget {
  final String text;
  const _ServiceChip(this.text);
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Center(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.25), borderRadius: BorderRadius.circular(12)),
            child: Text(text, style: const TextStyle(color: Colors.white, fontSize: 13)),
          ),
        ),
      );
}

class _Bubble extends StatelessWidget {
  final Event event;
  final Timeline timeline;
  final Room room;
  final bool showName;
  const _Bubble({required this.event, required this.timeline, required this.room, required this.showName});

  @override
  Widget build(BuildContext context) {
    final e = event.getDisplayEvent(timeline);
    final mine = event.senderId == client.userID;
    final hint = Theme.of(context).hintColor;
    final time = DateFormat.Hm('ru').format(event.originServerTs);
    final name = event.senderFromMemoryOrFallback.calcDisplayname();
    Widget content;
    if (event.redacted) {
      content = Text('Сообщение удалено', style: TextStyle(fontStyle: FontStyle.italic, color: hint));
    } else if (e.type == EventTypes.Encrypted) {
      content = Text('🔒 Не удалось расшифровать. Подтвердите устройство или дождитесь ключей.', style: TextStyle(fontStyle: FontStyle.italic, color: hint));
    } else if (e.type == EventTypes.CallInvite) {
      content = Text(mine ? '📞 Исходящий звонок' : '📞 Входящий звонок');
    } else if (e.messageType == MessageTypes.Image || e.type == EventTypes.Sticker) {
      content = _Image(e, sticker: e.type == EventTypes.Sticker);
    } else if (e.messageType == MessageTypes.File || e.messageType == MessageTypes.Audio || e.messageType == MessageTypes.Video) {
      content = Row(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.insert_drive_file_outlined),
        const SizedBox(width: 6),
        Flexible(child: Text(e.body)),
      ]);
    } else {
      final edited = e.eventId != event.eventId || event.hasAggregatedEvents(timeline, RelationshipTypes.edit);
      content = Text.rich(TextSpan(children: [
        TextSpan(text: e.calcUnlocalizedBody(hideReply: true)),
        if (edited) TextSpan(text: '  изм.', style: TextStyle(fontSize: 11, color: hint)),
      ]), style: TextStyle(fontSize: 16, color: mine ? Bubbles.outText(context) : null));
    }
    final replyId = event.content.tryGetMap<String, Object?>('m.relates_to')?.tryGetMap<String, Object?>('m.in_reply_to')?.tryGet<String>('event_id');
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.8),
        margin: EdgeInsets.only(top: showName ? 6 : 2, bottom: 2),
        padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
        decoration: BoxDecoration(color: mine ? Bubbles.out(context) : Bubbles.inc(context), borderRadius: BorderRadius.circular(16)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          if (showName && !mine)
            Text(name, style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14, color: Theme.of(context).colorScheme.primary)),
          if (replyId != null) _ReplyPreview(room: room, timeline: timeline, eventId: replyId),
          content,
          Align(
            alignment: Alignment.bottomRight,
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Text(time, style: TextStyle(fontSize: 11, color: hint)),
              if (mine) ...[
                const SizedBox(width: 3),
                Icon(
                  event.status.isSending ? Icons.schedule : event.status.isError ? Icons.error_outline : Icons.done_all,
                  size: 14,
                  color: event.status.isError ? Colors.redAccent : hint,
                ),
              ],
            ]),
          ),
        ]),
      ),
    );
  }
}

class _ReplyPreview extends StatelessWidget {
  final Room room;
  final Timeline timeline;
  final String eventId;
  const _ReplyPreview({required this.room, required this.timeline, required this.eventId});
  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    return FutureBuilder<Event?>(
      future: room.getEventById(eventId),
      builder: (_, s) {
        final e = s.data;
        return Container(
          margin: const EdgeInsets.only(bottom: 4),
          padding: const EdgeInsets.only(left: 8),
          decoration: BoxDecoration(border: Border(left: BorderSide(color: accent, width: 3))),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(e?.senderFromMemoryOrFallback.calcDisplayname() ?? '…', style: TextStyle(color: accent, fontWeight: FontWeight.w600, fontSize: 13)),
            Text(e == null ? '' : e.getDisplayEvent(timeline).calcUnlocalizedBody(hideReply: true), maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13)),
          ]),
        );
      },
    );
  }
}

final Map<String, Future<Uint8List?>> _images = {};

class _Image extends StatelessWidget {
  final Event event;
  final bool sticker;
  const _Image(this.event, {this.sticker = false});

  Future<Uint8List?> _load({bool full = false}) => _images.putIfAbsent('${event.eventId}$full', () async {
        try {
          final f = await event.downloadAndDecryptAttachment(getThumbnail: !full && event.hasThumbnail);
          return f.bytes;
        } catch (_) {
          return null;
        }
      });

  @override
  Widget build(BuildContext context) {
    final info = event.content.tryGetMap<String, Object?>('info');
    final w = (info?['w'] as num?)?.toDouble();
    final h = (info?['h'] as num?)?.toDouble();
    final maxW = sticker ? 160.0 : MediaQuery.sizeOf(context).width * 0.7;
    final ratio = (w != null && h != null && w > 0 && h > 0) ? w / h : 1.0;
    return GestureDetector(
      onTap: sticker
          ? null
          : () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => Scaffold(
                  backgroundColor: Colors.black,
                  appBar: AppBar(backgroundColor: Colors.black, foregroundColor: Colors.white),
                  body: FutureBuilder<Uint8List?>(
                    future: _load(full: true),
                    builder: (_, s) => s.data == null
                        ? const Center(child: CircularProgressIndicator())
                        : InteractiveViewer(maxScale: 6, child: Center(child: Image.memory(s.data!, fit: BoxFit.contain))),
                  ),
                ),
              )),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: SizedBox(
          width: maxW,
          child: AspectRatio(
            aspectRatio: ratio.clamp(0.5, 2.5),
            child: FutureBuilder<Uint8List?>(
              future: _load(),
              builder: (_, s) => s.data == null
                  ? Container(color: Colors.black12, child: s.connectionState == ConnectionState.done ? const Icon(Icons.broken_image_outlined) : null)
                  : Image.memory(s.data!, fit: sticker ? BoxFit.contain : BoxFit.cover, gaplessPlayback: true),
            ),
          ),
        ),
      ),
    );
  }
}
