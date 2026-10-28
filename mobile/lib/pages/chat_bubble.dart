part of 'chat.dart';

// Пузырь сообщения и ответ-цитата.

/// Один раз за запуск на каждую сессию: подтянуть ключ из резервной копии на сервере.
final Set<String> _keyTried = {};
void _autoLoadKey(Event e) {
  final sid = e.content.tryGet<String>('session_id');
  final enc = client.encryption;
  if (sid == null || enc == null || !_keyTried.add(sid)) return;
  enc.keyManager.loadSingleKey(e.room.id, sid).catchError((Object err) {
    // ключа нет в резервной копии — обычное дело (сообщение зашифровали до её включения), не ошибка
    if ('$err'.contains('M_NOT_FOUND')) return;
    Diag.err('Ключ из резервной копии', err);
  });
}
/// Сообщения с неподтверждённых устройств, которые вы решили показать (до перезапуска).
final _revealedUnverified = ValueNotifier<Set<String>>({});

class _Bubble extends StatelessWidget {
  final Event event;
  final Timeline timeline;
  final Room room;
  final bool showName, tail, showAvatar, avatarSpace;
  final void Function(String key) onReact;
  final void Function(String id) onReplyTap;
  final List<Event>? album; // несколько фото/видео одним сообщением
  final String? highlight; // подсветка при поиске в чате
  final int threadCount; // ответов в ветке
  final VoidCallback? onThread;
  final VoidCallback? onMenu; // меню сообщения (правая кнопка мыши по невыделенному тексту)
  const _Bubble({
    this.onMenu,
    this.threadCount = 0,
    this.onThread,
    this.album,
    this.highlight,
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

  /// Компьютер: текст сообщения можно выделить мышью и скопировать (Ctrl+C / ⌘C или правой кнопкой).
  /// Правая кнопка по невыделенному тексту, как и раньше, открывает меню сообщения.
  Widget _selectable(Widget child) {
    if (!isDesktop || onMenu == null) return child;
    return SelectionArea(
      contextMenuBuilder: (context, st) {
        final items = st.contextMenuButtonItems;
        if (!items.any((b) => b.type == ContextMenuButtonType.copy)) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            st.hideToolbar();
            onMenu?.call();
          });
          return const SizedBox.shrink();
        }
        return AdaptiveTextSelectionToolbar.buttonItems(
          anchors: st.contextMenuAnchors,
          buttonItems: [
            for (final b in items)
              if (b.type == ContextMenuButtonType.copy || b.type == ContextMenuButtonType.selectAll) b,
            ContextMenuButtonItem(
              label: 'Действия с сообщением',
              onPressed: () {
                st.hideToolbar();
                onMenu?.call();
              },
            ),
          ],
        );
      },
      child: child,
    );
  }

  bool _readByOthers() {
    final ts = event.originServerTs.millisecondsSinceEpoch;
    return readByOthersSince(room, ts);
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
    // у тёзок в группе — с логином, чтобы под чужое имя нельзя было замаскироваться
    final name = memberName(room, event.senderId, name: sender.calcDisplayname());
    final isSticker = e.type == EventTypes.Sticker && !event.redacted;
    final isImage = e.messageType == MessageTypes.Image && !event.redacted;
    // одни эмодзи: обычный текст без ответа, пересылки и предупреждений — крупно, без пузыря
    final jumbo = !event.redacted &&
            e.type == EventTypes.Message &&
            e.messageType == MessageTypes.Text &&
            highlight == null &&
            forwardedFrom(e) == null &&
            e.content.tryGetMap<String, Object?>('m.relates_to')?['m.in_reply_to'] == null
        ? jumboEmojiCount(e.body)
        : null;
    final edited = !event.redacted && (e.eventId != event.eventId || event.aggregatedEvents(timeline, RelationshipTypes.edit).any((x) => x.senderId == event.senderId));

    // реакции
    final reactions = <String, List<Event>>{};
    for (final r in event.aggregatedEvents(timeline, RelationshipTypes.reaction)) {
      var k = r.content.tryGetMap<String, Object?>('m.relates_to')?['key'];
      if (k is! String || k.isEmpty) continue;
      if (k.characters.length > 16) k = '${k.characters.take(16)}…'; // длинные «реакции»-тексты обрезаем
      final list = reactions[k] ??= [];
      if (!list.any((x) => x.senderId == r.senderId)) list.add(r); // один человек — один голос за реакцию
    }

    final exp = expiryOf(event);
    // проверяем и исходное сообщение, и показанную правку (её мог прислать другой отправитель-устройство)
    final warn = event.redacted ? null : (Trust.instance.senderWarning(event) ?? (e.eventId != event.eventId ? Trust.instance.senderWarning(e) : null));
    // в защищённом чате пришло сообщение без шифрования (так его мог подложить сервер) — помечаем
    final plain = room.encrypted &&
        !event.redacted &&
        !event.status.isSending &&
        !event.status.isError &&
        event.originalSource == null &&
        (event.type == EventTypes.Message || event.type == EventTypes.Sticker);
    Widget metaOf(Color mc) => Row(mainAxisSize: MainAxisSize.min, children: [
      if (plain)
        const Tooltip(
          message: 'Это сообщение пришло без шифрования. В защищённом чате так не должно быть — его мог подменить сервер или его отправили до включения шифрования.',
          triggerMode: TooltipTriggerMode.tap,
          child: Padding(padding: EdgeInsets.only(right: 3), child: Icon(Icons.lock_open_rounded, size: 15, color: Colors.redAccent)),
        ),
      if (warn != null)
        Tooltip(
          message: warn,
          triggerMode: TooltipTriggerMode.tap,
          child: Padding(padding: const EdgeInsets.only(right: 3), child: Icon(Icons.gpp_maybe, size: 15, color: Colors.orange.shade700)),
        ),
      if (exp > 0)
        ValueListenableBuilder<int>(
          valueListenable: ttlTick,
          builder: (_, __, ___) => Text('🔥${fmtLeft(exp - DateTime.now().millisecondsSinceEpoch)} ', style: TextStyle(fontSize: 11.5, color: mc)),
        ),
      if (edited) Text('изм. ', style: TextStyle(fontSize: 11.5, color: mc)),
      Text(time, style: TextStyle(fontSize: 11.5, color: mc)),
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
          color: event.status.isError ? Colors.redAccent : mc,
        ),
      ],
    ]);

    final meta = metaOf(metaColor);
    // время поверх фото, видео и на стикере — белое на тёмной подложке, как в Telegram
    final metaOnMedia = Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.38), borderRadius: BorderRadius.circular(10)),
      child: metaOf(Colors.white),
    );

    Widget content;
    if (event.redacted) {
      content = Text('Сообщение удалено', style: TextStyle(fontStyle: FontStyle.italic, color: hint));
    } else if (e.type == EventTypes.Encrypted) {
      // ключ ещё не пришёл: сначала тихо пробуем взять его из резервной копии
      _autoLoadKey(e);
      content = Row(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.center, children: [
        Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(color: accent.withValues(alpha: 0.14), shape: BoxShape.circle),
          child: Icon(Icons.lock_clock_rounded, size: 19, color: accent),
        ),
        const SizedBox(width: 10),
        Flexible(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Text('Сообщение ещё не расшифровано', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14.5, color: mine ? Bubbles.outText(context) : null)),
            const SizedBox(height: 2),
            if (e.content['can_request_session'] == true)
              InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: () async {
                  try {
                    await e.requestKey();
                    if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Запрос ключа отправлен')));
                  } catch (_) {}
                },
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Text('Запросить ключ у ваших устройств', style: TextStyle(color: accent, fontSize: 13.5, fontWeight: FontWeight.w500)),
                ),
              )
            else
              Text('Ключ загружается…', style: TextStyle(color: hint, fontSize: 13)),
          ]),
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
        onOpen: () {
          void ext(Event m) => openAttachment(m, (s) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s))), context: context);
          if (!videoSupported) return ext(e);
          // как фото: общий просмотр с листанием, видео играет внутри
          final st = context.findAncestorStateOfType<_ChatPageState>();
          openMediaViewer(context, st?._mediaList() ?? [e], e, openExternally: ext);
        },
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
        onTap: () => openAttachment(e, (s) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s))), context: context),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          CircleAvatar(
            radius: 22,
            backgroundColor: mine ? const Color(0xFF4FAE4E) : accent,
            child: const Icon(Icons.insert_drive_file, color: Colors.white),
          ),
          const SizedBox(width: 10),
          Flexible(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(shownFileName(e), maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w500)),
              if (size != null) Text(_size(size), style: TextStyle(fontSize: 12.5, color: hint)),
            ]),
          ),
        ]),
      );
    } else if (jumbo != null) {
      // одни эмодзи (1–3) — крупно и без пузыря, как в Telegram
      content = _selectable(Text(e.body.trim(), style: TextStyle(fontSize: jumboEmojiSize(jumbo), height: 1.15)));
    } else {
      content = _selectable(RichMessage(
        event: e,
        highlight: highlight,
        style: TextStyle(fontSize: 16, height: 1.3, color: mine ? Bubbles.outText(context) : Theme.of(context).textTheme.bodyLarge?.color),
        // в своих пузырях ссылка — цвета текста (фиолетовая на фиолетовом не читается), в чужих — светлее в тёмной теме
        linkColor: mine
            ? Bubbles.outText(context)
            : Theme.of(context).brightness == Brightness.dark
                ? Color.lerp(accent, Colors.white, 0.35)
                : accent,
      ));
    }

    // подпись к фото, видео или файлу — под вложением, как в Telegram
    final caption = event.redacted || (album != null && album!.length > 1) ? null : captionOf(e);
    if (caption != null) {
      content = Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        content,
        const SizedBox(height: 6),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2),
          child: _selectable(RichMessage(
            event: e,
            highlight: highlight,
            style: TextStyle(fontSize: 16, height: 1.3, color: mine ? Bubbles.outText(context) : Theme.of(context).textTheme.bodyLarge?.color),
            linkColor: mine ? Bubbles.outText(context) : accent,
          )),
        ),
      ]);
    }

    // устройство, которое собеседник сам не подтвердил, — сообщение видно сразу, с красной пометкой (как в Element);
    // опасные случаи (чужой ключ, неизвестное устройство, ключ переслан не автором) — скрыто до «Показать»
    if (warn == Trust.unverifiedDeviceWarning) {
      final shown = content;
      content = Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.gpp_maybe_outlined, color: Colors.redAccent, size: 15),
            const SizedBox(width: 4),
            Flexible(child: Text('С неподтверждённого устройства', style: TextStyle(color: Colors.redAccent.shade200, fontSize: 12.5))),
          ]),
        ),
        shown,
      ]);
    }
    final untrustedDevice = warn != null && warn != Trust.unverifiedDeviceWarning;
    if (untrustedDevice) {
      final shown = content;
      content = ValueListenableBuilder<Set<String>>(
        valueListenable: _revealedUnverified,
        builder: (context, set, _) => set.contains(event.eventId)
            ? shown
            : Row(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.gpp_bad_outlined, color: Colors.redAccent, size: 22),
                const SizedBox(width: 8),
                Flexible(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                    Text('Скрыто: подлинность не подтверждена', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14, color: mine ? Bubbles.outText(context) : null)),
                    TextButton(
                      style: TextButton.styleFrom(padding: EdgeInsets.zero, visualDensity: VisualDensity.compact, minimumSize: Size.zero, tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                      onPressed: () => _revealedUnverified.value = {..._revealedUnverified.value, event.eventId},
                      child: const Text('Показать'),
                    ),
                  ]),
                ),
              ]),
      );
    }
    final replyId = event.content.tryGetMap<String, Object?>('m.relates_to')?.tryGetMap<String, Object?>('m.in_reply_to')?.tryGet<String>('event_id');
    final maxW = min(paneWidth(context) * (avatarSpace ? 0.74 : 0.8), 520.0);
    // стикер, «кружок» и крупные эмодзи — без пузыря, как в Telegram; предупреждение о подлинности — только в пузыре
    final bareMedia = isSticker || (isRound(e) && !event.redacted) || (jumbo != null && warn == null && !plain);
    final isText = !isImage && !isSticker && !isPollStart(e) && e.messageType != MessageTypes.Audio && e.messageType != MessageTypes.File && e.messageType != MessageTypes.Video;
    final fwd = event.redacted ? null : forwardedFrom(e);
    final mediaOnly = !event.redacted && (isImage || e.messageType == MessageTypes.Video || (album != null && album!.length > 1)) && !isRound(e) && caption == null;

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
        Padding(padding: const EdgeInsets.only(top: 2), child: metaOnMedia),
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
            child: GestureDetector(
              // адрес сервера в пузыре не показываем; по нажатию — откуда пересланное, со слов отправителя
              onTap: () {
                final addr = forwardedAddress(e);
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                    content: Text(addr == null ? 'Автор указан пересылающим и не проверен' : 'Автор: $addr — со слов того, кто переслал')));
              },
              child: Text('Переслано от $fwd', style: TextStyle(fontSize: 13, color: accent, fontStyle: FontStyle.italic)),
            ),
          ),
        if (replyId != null) _ReplyPreview(room: room, timeline: timeline, eventId: replyId, onTap: onReplyTap),
        if (isText)
          // время «обтекается» текстом, как в Telegram
          Wrap(alignment: WrapAlignment.end, crossAxisAlignment: WrapCrossAlignment.end, spacing: 8, children: [content, Padding(padding: const EdgeInsets.only(top: 4), child: meta)])
        else if (mediaOnly && reactRow == null)
          // фото и видео без подписи — время прямо на картинке, пузырь ровно по её размеру
          Stack(children: [content, Positioned(right: 6, bottom: 6, child: metaOnMedia)])
        else ...[
          content,
          if (reactRow == null) Align(alignment: Alignment.bottomRight, child: Padding(padding: const EdgeInsets.only(top: 3), child: meta)),
        ],
        if (reactRow != null)
          Row(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.end, children: [
            Flexible(child: reactRow),
            if (!isText) ...[const SizedBox(width: 8), meta],
          ]),
        // ответы в ветке — как в Telegram: «3 ответа ›» под сообщением
        if (threadCount > 0 && onThread != null)
          InkWell(
            onTap: onThread,
            borderRadius: BorderRadius.circular(10),
            child: Padding(
              padding: const EdgeInsets.only(top: 6, bottom: 2),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.forum_rounded, size: 16, color: mine ? metaColor : accent),
                const SizedBox(width: 5),
                Text(threadCountText(threadCount), style: TextStyle(color: mine ? metaColor : accent, fontWeight: FontWeight.w600, fontSize: 13.5)),
                Icon(Icons.chevron_right_rounded, size: 18, color: mine ? metaColor : accent),
              ]),
            ),
          ),
      ]);
      body = DecoratedBox(
        decoration: ShapeDecoration(
          color: mine ? Bubbles.out(context) : Bubbles.inc(context),
          shape: TgBubbleBorder(mine: mine, tail: tail),
          shadows: const [BoxShadow(color: Color(0x14000000), blurRadius: 1.5, offset: Offset(0, 1))],
        ),
        child: Padding(
          padding: EdgeInsets.fromLTRB(mediaOnly ? 3 : 10, mediaOnly ? 3 : 6, mediaOnly ? 3 : 10, mediaOnly ? 3 : 6).add(TgBubbleBorder(mine: mine, tail: tail).dimensions),
          // не текст — ширина пузыря по содержимому, а не по самой широкой строке времени
          child: isText || e.messageType == MessageTypes.Audio || event.redacted ? inner : IntrinsicWidth(child: inner),
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
              Text(e == null ? '…' : memberName(room, e.senderId, name: e.senderFromMemoryOrFallback.calcDisplayname()), maxLines: 1, style: TextStyle(color: c, fontWeight: FontWeight.w600, fontSize: 13)),
              Text(e == null ? '' : eventPreview(e, timeline), maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13)),
            ]),
          ),
        );
      },
    );
  }
}

// не больше 60 картинок в памяти (уменьшенные копии лёгкие, но фото целиком — нет)

/// Имя файла для показа: без невидимых символов и «переворота» текста — иначе «отчёт\u202Efdp.exe»
/// выглядит как безобидный «…exe.pdf». Сохранение и открытие файла чистят имя так же.
String shownFileName(Event e) => cleanShownName(e.content.tryGet<String>('filename') ?? e.body);

String cleanShownName(String name) {
  final n = name
      .replaceAll(RegExp(r'[\u0000-\u001f\u007f\u200b-\u200f\u202a-\u202e\u2066-\u2069\ufeff]'), '')
      .trim();
  return n.isEmpty ? 'Файл' : n;
}
