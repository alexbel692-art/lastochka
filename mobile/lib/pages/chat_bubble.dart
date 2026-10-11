part of 'chat.dart';

// Пузырь сообщения и ответ-цитата.
class _Bubble extends StatelessWidget {
  final Event event;
  final Timeline timeline;
  final Room room;
  final bool showName, tail, showAvatar, avatarSpace;
  final void Function(String key) onReact;
  final void Function(String id) onReplyTap;
  final List<Event>? album; // несколько фото/видео одним сообщением
  const _Bubble({
    this.album,
    required this.event,
    required this.timeline,
    required this.room,
    required this.showName,
    required this.tail,
    required this.showAvatar,
    required this.avatarSpace,
    required this.onReact,
    required this.onReplyTap,
  });

  bool _readByOthers() {
    final ts = event.originServerTs.millisecondsSinceEpoch;
    return room.receiptState.global.otherUsers.values.any((r) => r.ts >= ts);
  }

  @override
  Widget build(BuildContext context) {
    final e = event.getDisplayEvent(timeline);
    final mine = event.senderId == client.userID;
    final hint = Theme.of(context).hintColor;
    final accent = Theme.of(context).colorScheme.primary;
    final metaColor = mine ? (Theme.of(context).brightness == Brightness.dark ? Colors.white70 : const Color(0xFF4FAE4E)) : hint;
    final time = DateFormat.Hm('ru').format(event.originServerTs);
    final sender = event.senderFromMemoryOrFallback;
    final name = sender.calcDisplayname();
    final isSticker = e.type == EventTypes.Sticker && !event.redacted;
    final isImage = e.messageType == MessageTypes.Image && !event.redacted;
    final edited = !event.redacted && (e.eventId != event.eventId || event.hasAggregatedEvents(timeline, RelationshipTypes.edit));

    // реакции
    final reactions = <String, List<Event>>{};
    for (final r in event.aggregatedEvents(timeline, RelationshipTypes.reaction)) {
      final k = r.content.tryGetMap<String, Object?>('m.relates_to')?['key'];
      if (k is String) (reactions[k] ??= []).add(r);
    }

    final exp = expiryOf(event);
    // проверяем и исходное сообщение, и показанную правку (её мог прислать другой отправитель-устройство)
    final warn = event.redacted ? null : (Trust.instance.senderWarning(event) ?? (e.eventId != event.eventId ? Trust.instance.senderWarning(e) : null));
    final meta = Row(mainAxisSize: MainAxisSize.min, children: [
      if (warn != null)
        Tooltip(
          message: warn,
          triggerMode: TooltipTriggerMode.tap,
          child: Padding(padding: const EdgeInsets.only(right: 3), child: Icon(Icons.gpp_maybe, size: 15, color: Colors.orange.shade700)),
        ),
      if (exp > 0)
        ValueListenableBuilder<int>(
          valueListenable: ttlTick,
          builder: (_, __, ___) => Text('🔥${fmtLeft(exp - DateTime.now().millisecondsSinceEpoch)} ', style: TextStyle(fontSize: 11.5, color: metaColor)),
        ),
      if (edited) Text('изм. ', style: TextStyle(fontSize: 11.5, color: metaColor)),
      Text(time, style: TextStyle(fontSize: 11.5, color: metaColor)),
      if (mine) ...[
        const SizedBox(width: 3),
        Icon(
          event.status.isError
              ? Icons.error_outline
              : event.status.isSending
                  ? Icons.schedule
                  : _readByOthers()
                      ? Icons.done_all
                      : Icons.done,
          size: 15,
          color: event.status.isError ? Colors.redAccent : metaColor,
        ),
      ],
    ]);

    Widget content;
    if (event.redacted) {
      content = Text('Сообщение удалено', style: TextStyle(fontStyle: FontStyle.italic, color: hint));
    } else if (e.type == EventTypes.Encrypted) {
      content = Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        Text('🔒 Ожидание ключа расшифровки…', style: TextStyle(fontStyle: FontStyle.italic, color: hint)),
        if (e.content['can_request_session'] == true)
          TextButton.icon(
            style: TextButton.styleFrom(padding: EdgeInsets.zero, visualDensity: VisualDensity.compact),
            icon: const Icon(Icons.key, size: 16),
            label: const Text('Запросить ключ'),
            onPressed: () async {
              try {
                await e.requestKey();
                if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Запрос отправлен на ваши устройства и отправителю')));
              } catch (_) {}
            },
          ),
      ]);
    } else if (e.type == EventTypes.CallInvite) {
      content = Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(mine ? Icons.call_made : Icons.call_received, size: 18, color: mine ? Colors.green : accent),
        const SizedBox(width: 6),
        Text(mine ? 'Исходящий звонок' : 'Входящий звонок'),
      ]);
    } else if (isPollStart(e)) {
      content = PollView(event: event, timeline: timeline, accent: mine ? const Color(0xFF4FAE4E) : accent);
    } else if (album != null && album!.length > 1) {
      content = _Album(items: album!, width: min(paneWidth(context) * 0.7, 380.0));
    } else if (isRound(e)) {
      content = RoundVideo(event: e, openExternally: () => openAttachment(e, (s) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s)))));
    } else if (isImage || isSticker) {
      content = _Image(e, sticker: isSticker);
    } else if (e.messageType == MessageTypes.Audio) {
      content = VoiceMessage(event: e, color: mine ? const Color(0xFF4FAE4E) : accent);
    } else if (e.messageType == MessageTypes.Video) {
      content = VideoPreview(
        event: e,
        maxWidth: min(paneWidth(context) * 0.7, 360.0),
        onOpen: () => openVideo(context, e, () => openAttachment(e, (s) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s))))),
      );
    } else if (e.messageType == 'm.key.verification.request') {
      content = Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.verified_user_outlined, size: 18, color: mine ? const Color(0xFF4FAE4E) : accent),
        const SizedBox(width: 6),
        Flexible(child: Text(mine ? 'Запрос подтверждения устройства' : 'Собеседник запросил подтверждение устройства', style: TextStyle(fontStyle: FontStyle.italic, color: hint))),
      ]);
    } else if (e.messageType == MessageTypes.File) {
      final size = (e.content.tryGetMap<String, Object?>('info')?['size'] as num?)?.toInt();
      content = InkWell(
        onTap: () => openAttachment(e, (s) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s)))),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          CircleAvatar(
            radius: 22,
            backgroundColor: mine ? const Color(0xFF4FAE4E) : accent,
            child: const Icon(Icons.insert_drive_file, color: Colors.white),
          ),
          const SizedBox(width: 10),
          Flexible(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(e.content.tryGet<String>('filename') ?? e.body, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w500)),
              if (size != null) Text(_size(size), style: TextStyle(fontSize: 12.5, color: hint)),
            ]),
          ),
        ]),
      );
    } else {
      content = RichMessage(event: e, style: TextStyle(fontSize: 16, height: 1.3, color: mine ? Bubbles.outText(context) : Theme.of(context).textTheme.bodyLarge?.color));
    }

    final replyId = event.content.tryGetMap<String, Object?>('m.relates_to')?.tryGetMap<String, Object?>('m.in_reply_to')?.tryGet<String>('event_id');
    final maxW = min(paneWidth(context) * (avatarSpace ? 0.74 : 0.8), 520.0);
    final bareMedia = isSticker || (isRound(e) && !event.redacted); // стикер и «кружок» без пузыря, как в Telegram
    final isText = !isImage && !isSticker && !isPollStart(e) && e.messageType != MessageTypes.Audio && e.messageType != MessageTypes.File && e.messageType != MessageTypes.Video;
    final fwd = event.redacted ? null : forwardedFrom(e);

    final reactRow = reactions.isEmpty
        ? null
        : Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Wrap(spacing: 4, runSpacing: 4, children: [
              for (final MapEntry(:key, :value) in reactions.entries)
                GestureDetector(
                  onTap: () => onReact(key),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                    decoration: BoxDecoration(
                      color: value.any((r) => r.senderId == client.userID) ? (mine ? const Color(0xFF4FAE4E) : accent) : (mine ? const Color(0x334FAE4E) : accent.withValues(alpha: 0.13)),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Text('$key ${value.length}',
                        style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: value.any((r) => r.senderId == client.userID) ? Colors.white : (mine ? const Color(0xFF3A8C39) : accent))),
                  ),
                ),
            ]),
          );

    Widget body;
    if (bareMedia) {
      body = Column(crossAxisAlignment: mine ? CrossAxisAlignment.end : CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        if (replyId != null) _ReplyPreview(room: room, timeline: timeline, eventId: replyId, onTap: onReplyTap, boxed: true),
        content,
        if (reactRow != null) reactRow,
        Container(
          margin: const EdgeInsets.only(top: 2),
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.25), borderRadius: BorderRadius.circular(10)),
          child: DefaultTextStyle.merge(style: const TextStyle(color: Colors.white), child: IconTheme.merge(data: const IconThemeData(color: Colors.white), child: meta)),
        ),
      ]);
    } else {
      final inner = Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        if (showName && !mine)
          Padding(
            padding: const EdgeInsets.only(bottom: 2),
            child: Text(name, style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14, color: nameColor(event.senderId))),
          ),
        if (fwd != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 2),
            child: Text('Переслано от $fwd', style: TextStyle(fontSize: 13, color: accent, fontStyle: FontStyle.italic)),
          ),
        if (replyId != null) _ReplyPreview(room: room, timeline: timeline, eventId: replyId, onTap: onReplyTap),
        if (isText)
          // время «обтекается» текстом, как в Telegram
          Wrap(alignment: WrapAlignment.end, crossAxisAlignment: WrapCrossAlignment.end, spacing: 8, children: [content, Padding(padding: const EdgeInsets.only(top: 4), child: meta)])
        else ...[
          content,
          if (reactRow == null) Align(alignment: Alignment.bottomRight, child: Padding(padding: const EdgeInsets.only(top: 3), child: meta)),
        ],
        if (reactRow != null)
          Row(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.end, children: [
            Flexible(child: reactRow),
            if (!isText) ...[const SizedBox(width: 8), meta],
          ]),
      ]);
      body = DecoratedBox(
        decoration: ShapeDecoration(
          color: mine ? Bubbles.out(context) : Bubbles.inc(context),
          shape: TgBubbleBorder(mine: mine, tail: tail),
          shadows: const [BoxShadow(color: Color(0x14000000), blurRadius: 1.5, offset: Offset(0, 1))],
        ),
        child: Padding(
          padding: EdgeInsets.fromLTRB(isImage ? 4 : 10, isImage ? 4 : 6, isImage ? 4 : 10, isImage ? 4 : 6).add(TgBubbleBorder(mine: mine, tail: tail).dimensions),
          child: inner,
        ),
      );
    }

    final bubble = ConstrainedBox(constraints: BoxConstraints(maxWidth: maxW + TgBubbleBorder.tailW), child: body);
    return Padding(
      padding: EdgeInsets.only(top: showName ? 6 : 1.5, bottom: tail ? 4 : 1.5),
      child: Row(
        mainAxisAlignment: mine ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (avatarSpace && !mine)
            SizedBox(width: 38, child: showAvatar ? Avatar(mxc: sender.avatarUrl, name: name, size: 34) : null),
          Flexible(child: bubble),
        ],
      ),
    );
  }
}

String _size(int b) => b < 1024
    ? '$b Б'
    : b < 1024 * 1024
        ? '${(b / 1024).toStringAsFixed(0)} КБ'
        : '${(b / 1024 / 1024).toStringAsFixed(1)} МБ';

const _nameColors = [Color(0xFFE17076), Color(0xFF7BC862), Color(0xFFE5A64E), Color(0xFF65AADD), Color(0xFFA695E7), Color(0xFFEE7AAE), Color(0xFF6EC9CB), Color(0xFFFAA774)];
Color nameColor(String id) => _nameColors[id.hashCode.abs() % _nameColors.length];

class _ReplyPreview extends StatelessWidget {
  final Room room;
  final Timeline timeline;
  final String eventId;
  final void Function(String id) onTap;
  final bool boxed;
  const _ReplyPreview({required this.room, required this.timeline, required this.eventId, required this.onTap, this.boxed = false});
  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Event?>(
      future: room.getEventById(eventId),
      builder: (_, s) {
        final e = s.data;
        final c = e == null ? Theme.of(context).colorScheme.primary : nameColor(e.senderId);
        return GestureDetector(
          onTap: () => onTap(eventId),
          child: Container(
            margin: const EdgeInsets.only(bottom: 4),
            padding: const EdgeInsets.fromLTRB(8, 3, 8, 3),
            decoration: BoxDecoration(
              color: boxed ? Theme.of(context).scaffoldBackgroundColor : c.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(6),
              border: Border(left: BorderSide(color: c, width: 3)),
            ),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              Text(e?.senderFromMemoryOrFallback.calcDisplayname() ?? '…', maxLines: 1, style: TextStyle(color: c, fontWeight: FontWeight.w600, fontSize: 13)),
              Text(e == null ? '' : eventPreview(e, timeline), maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13)),
            ]),
          ),
        );
      },
    );
  }
}

// не больше 60 картинок в памяти (уменьшенные копии лёгкие, но фото целиком — нет)
