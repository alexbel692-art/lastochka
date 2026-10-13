// Ветка обсуждения (тред): ответы на одно сообщение отдельно от общей ленты — стандарт Matrix
// (m.thread), те же ветки видны в Element.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:matrix/matrix.dart';

import '../widgets/wallpaper.dart';
import '../chat/formatting.dart';
import '../main.dart';
import '../system/trust.dart';
import '../system/diag.dart';
import '../theme.dart';
import '../widgets/avatar.dart';

class ThreadPage extends StatefulWidget {
  final Room room;
  final Event root;
  const ThreadPage({super.key, required this.room, required this.root});
  @override
  State<ThreadPage> createState() => _ThreadPageState();
}

class _ThreadPageState extends State<ThreadPage> {
  final Map<String, Event> _replies = {};
  final _text = TextEditingController();
  final _scroll = ScrollController();
  StreamSubscription? _sub;
  bool _loading = true, _sending = false;

  Room get room => widget.room;

  @override
  void initState() {
    super.initState();
    _load();
    // новые ответы приходят обычной синхронизацией
    _sub = client.onTimelineEvent.stream.where((e) => e.roomId == room.id).listen(_take);
  }

  @override
  void dispose() {
    _sub?.cancel();
    _text.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _take(Event e) async {
    var ev = e;
    if (ev.relationshipType != RelationshipTypes.thread || ev.relationshipEventId != widget.root.eventId) return;
    if (ev.type == EventTypes.Encrypted && client.encryption != null) {
      try {
        ev = await client.encryption!.decryptRoomEvent(ev);
      } catch (_) {}
    }
    if (!mounted) return;
    setState(() {
      // отправленный нами ответ: локальная копия (по номеру отправки) заменяется настоящей
      final tx = ev.transactionId;
      if (tx != null) _replies.remove(tx);
      _replies[ev.eventId] = ev;
    });
  }

  Future<void> _load() async {
    try {
      String? from;
      for (var page = 0; page < 10; page++) {
        final r = await client.getRelatingEventsWithRelType(room.id, widget.root.eventId, RelationshipTypes.thread, from: from, limit: 100);
        for (final m in r.chunk) {
          var ev = Event.fromMatrixEvent(m, room);
          if (ev.type == EventTypes.Encrypted && client.encryption != null) {
            try {
              ev = await client.encryption!.decryptRoomEvent(ev);
            } catch (_) {}
          }
          _replies[ev.eventId] = ev;
        }
        from = r.nextBatch;
        if (from == null) break;
      }
    } catch (e) {
      Diag.err('Загрузка ветки', e);
    }
    if (mounted) setState(() => _loading = false);
  }

  List<Event> get _sorted => _replies.values.where((e) => !e.redacted && e.relationshipType != RelationshipTypes.edit).toList()
    ..sort((a, b) => a.originServerTs.compareTo(b.originServerTs));

  Future<void> _send() async {
    final t = _text.text.trim();
    if (t.isEmpty || _sending) return;
    if (Trust.instance.sendBlocked(room)) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('У собеседника сменился ключ — подтвердите его в чате, прежде чем писать')));
      return;
    }
    setState(() => _sending = true);
    final last = _sorted.lastOrNull;
    try {
      await room.sendTextEvent(t, threadRootEventId: widget.root.eventId, threadLastEventId: last?.eventId ?? widget.root.eventId);
      _text.clear();
    } catch (e) {
      Diag.err('Ответ в ветке', e);
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Не отправлено — проверьте подключение')));
    }
    if (mounted) setState(() => _sending = false);
  }

  Widget _msg(Event e, {bool root = false}) {
    final mine = e.senderId == client.userID;
    final u = e.senderFromMemoryOrFallback;
    final t = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      child: Row(crossAxisAlignment: CrossAxisAlignment.end, mainAxisAlignment: mine ? MainAxisAlignment.end : MainAxisAlignment.start, children: [
        if (!mine) ...[Avatar(mxc: u.avatarUrl, name: u.calcDisplayname(), size: 32), const SizedBox(width: 6)],
        Flexible(
          child: Container(
            constraints: const BoxConstraints(maxWidth: 520),
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
            decoration: BoxDecoration(
              color: root ? t.colorScheme.primary.withValues(alpha: 0.12) : (mine ? Bubbles.out(context) : Bubbles.inc(context)),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (!mine) Text(u.calcDisplayname(), style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13.5, color: t.colorScheme.primary)),
              e.type == EventTypes.Encrypted
                  ? Text('Сообщение ещё не расшифровано', style: TextStyle(fontStyle: FontStyle.italic, color: t.hintColor))
                  : RichMessage(event: e, style: TextStyle(fontSize: 15.5, height: 1.3, color: mine && !root ? Bubbles.outText(context) : t.textTheme.bodyLarge?.color)),
              Align(alignment: Alignment.bottomRight, child: Text(DateFormat.Hm('ru').format(e.originServerTs), style: TextStyle(fontSize: 11.5, color: t.hintColor))),
            ]),
          ),
        ),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final list = _sorted;
    final hint = Theme.of(context).hintColor;
    return Scaffold(
      appBar: AppBar(
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Ветка'),
          Text(list.isEmpty ? room.getLocalizedDisplayname() : '${list.length} ${_plural(list.length)} · ${room.getLocalizedDisplayname()}',
              style: TextStyle(fontSize: 13, color: hint, fontWeight: FontWeight.w400)),
        ]),
      ),
      body: ChatWallpaper(
        child: Column(children: [
          Expanded(
            child: ListView(controller: _scroll, padding: const EdgeInsets.symmetric(vertical: 8), children: [
              _msg(widget.root, root: true),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                    decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.25), borderRadius: BorderRadius.circular(12)),
                    child: Text(_loading ? 'Загрузка ответов…' : list.isEmpty ? 'Ответов пока нет' : 'Ответы', style: const TextStyle(color: Colors.white, fontSize: 12.5)),
                  ),
                ),
              ),
              for (final e in list) _msg(e),
            ]),
          ),
          Material(
            color: Theme.of(context).scaffoldBackgroundColor,
            child: SafeArea(
              top: false,
              child: Row(children: [
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: _text,
                    enableIMEPersonalizedLearning: false,
                    minLines: 1,
                    maxLines: 5,
                    textCapitalization: TextCapitalization.sentences,
                    onSubmitted: (_) => _send(),
                    decoration: const InputDecoration(hintText: 'Ответить в ветке', filled: false, border: InputBorder.none),
                  ),
                ),
                IconButton(onPressed: _sending ? null : _send, icon: Icon(Icons.send_rounded, color: Theme.of(context).colorScheme.primary)),
              ]),
            ),
          ),
        ]),
      ),
    );
  }
}

String _plural(int n) {
  final m10 = n % 10, m100 = n % 100;
  if (m10 == 1 && m100 != 11) return 'ответ';
  if (m10 >= 2 && m10 <= 4 && (m100 < 12 || m100 > 14)) return 'ответа';
  return 'ответов';
}

String threadCountText(int n) => '$n ${_plural(n)}';
