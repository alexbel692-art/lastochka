part of 'chat.dart';

// Голосовые, реакции, закрепление, переход к сообщению, меню сообщения.
extension _ChatMessages on _ChatPageState {
  // ---------- голосовые ----------
  Future<void> _startRec() async {
    final err = await _rec.start();
    if (err != null) return _toast(err);
    HapticFeedback.mediumImpact();
    _recTimer = Timer.periodic(const Duration(milliseconds: 200), (_) {
      if (mounted) _set(() {});
      if (_rec.elapsedMs > 15 * 60 * 1000) _stopRec(send: true);
    });
    _set(() {});
  }

  Future<void> _stopRec({required bool send}) async {
    _recTimer?.cancel();
    if (!send) {
      await _rec.cancel();
      return _set(() {});
    }
    final r = await _rec.stop();
    _set(() {});
    if (r == null) return _toast('Слишком короткое голосовое');
    final reply = _replyTo;
    _set(() => _replyTo = null);
    try {
      await sendVoice(room, r.$1, r.$2, r.$3, inReplyTo: reply, extra: ttlExtra(room));
      _toBottom();
    } catch (_) {
      _toast('Голосовое не отправлено');
    }
  }

  // ---------- реакции, закрепление ----------
  Future<void> _react(Event e, String key) async {
    final tl = _tl;
    if (tl == null) return;
    final mine = e.aggregatedEvents(tl, RelationshipTypes.reaction).where((r) =>
        r.senderId == client.userID && r.content.tryGetMap<String, Object?>('m.relates_to')?['key'] == key);
    try {
      if (mine.isNotEmpty) {
        for (final r in mine) {
          await r.redactEvent();
        }
      } else {
        await room.sendReaction(e.eventId, key);
      }
    } catch (_) {
      _toast('Не получилось');
    }
  }

  bool get _canPin => room.canChangeStateEvent('m.room.pinned_events');

  Future<void> _togglePin(Event e) async {
    final ids = List<String>.from(room.pinnedEventIds);
    final had = ids.remove(e.eventId);
    if (!had) ids.add(e.eventId);
    try {
      await room.setPinnedEvents(ids);
      _pinIdx = -1;
      _toast(had ? 'Сообщение откреплено' : 'Сообщение закреплено');
    } catch (_) {
      _toast('Нет прав закреплять сообщения');
    }
  }

  Future<void> _jumpTo(String id) async {
    // сообщение может быть и выше, и ниже текущего места — ищем от самых новых вверх
    if (_keys[id]?.currentContext == null && _scroll.hasClients) _scroll.jumpTo(0);
    await Future.delayed(const Duration(milliseconds: 30));
    for (var i = 0; i < 40 && mounted; i++) {
      final ctx = _keys[id]?.currentContext;
      if (ctx != null) {
        await Scrollable.ensureVisible(ctx, alignment: 0.5, duration: const Duration(milliseconds: 300));
        _set(() => _flash = id);
        Future.delayed(const Duration(milliseconds: 1200), () => mounted ? _set(() => _flash = null) : null);
        return;
      }
      final tl = _tl;
      if (tl == null) return;
      final loaded = tl.events.any((e) => e.eventId == id);
      if (!loaded && tl.canRequestHistory) {
        await _more();
      }
      if (!_scroll.hasClients) return;
      final pos = _scroll.position;
      final target = min(pos.pixels + pos.viewportDimension * 0.9, pos.maxScrollExtent);
      if (target == pos.pixels && !tl.canRequestHistory) break;
      _scroll.jumpTo(target);
      await Future.delayed(const Duration(milliseconds: 30));
    }
    _toast('Сообщение не найдено — возможно, оно удалено');
  }

  // ---------- меню сообщения ----------
  Future<void> _actions(Event e) async {
    final tl = _tl;
    if (tl == null || e.status.isSending) return;
    if (e.status.isError) return _failedMenu(e);
    final mine = e.senderId == client.userID;
    final disp = e.getDisplayEvent(tl);
    final pinned = room.pinnedEventIds.contains(e.eventId);
    final isText = disp.messageType == MessageTypes.Text || disp.messageType == MessageTypes.Notice || disp.messageType == MessageTypes.Emote;
    final isImg = disp.messageType == MessageTypes.Image || e.type == EventTypes.Sticker;
    final a = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (c) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          if (!e.redacted)
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
              child: Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
                for (final r in quickReactions)
                  InkWell(
                    borderRadius: BorderRadius.circular(20),
                    onTap: () => Navigator.pop(c, 'react:$r'),
                    child: Padding(padding: const EdgeInsets.all(6), child: Text(r, style: const TextStyle(fontSize: 28))),
                  ),
              ]),
            ),
          const Divider(height: 1),
          ListTile(leading: const Icon(Icons.reply), title: const Text('Ответить'), onTap: () => Navigator.pop(c, 'reply')),
          if (!e.redacted && e.relationshipType != RelationshipTypes.thread && !room.isDirectChat)
            ListTile(leading: const Icon(Icons.forum_outlined), title: const Text('Обсудить в ветке'), onTap: () => Navigator.pop(c, 'thread')),
          if (mine && !room.isDirectChat && !e.redacted)
            ListTile(leading: const Icon(Icons.done_all_rounded), title: const Text('Кто прочитал'), onTap: () => Navigator.pop(c, 'readers')),
          if (!e.redacted && e.hasAggregatedEvents(tl, RelationshipTypes.edit))
            ListTile(leading: const Icon(Icons.history_rounded), title: const Text('История правок'), onTap: () => Navigator.pop(c, 'history')),
          if (canForward(e)) ListTile(leading: const Icon(Icons.forward_outlined), title: const Text('Переслать'), onTap: () => Navigator.pop(c, 'forward')),
          ListTile(leading: const Icon(Icons.check_circle_outline), title: const Text('Выбрать'), onTap: () => Navigator.pop(c, 'select')),
          if (isPollStart(e) && !e.redacted && (mine || room.ownPowerLevel.level >= 50) && pollStateOf(e, tl) == null)
            ListTile(leading: const Icon(Icons.stop_circle_outlined), title: const Text('Завершить опрос'), onTap: () => Navigator.pop(c, 'endpoll')),
          if (mine && isText && !e.redacted) ListTile(leading: const Icon(Icons.edit_outlined), title: const Text('Изменить'), onTap: () => Navigator.pop(c, 'edit')),
          if (isText && !e.redacted) ListTile(leading: const Icon(Icons.copy), title: const Text('Копировать текст'), onTap: () => Navigator.pop(c, 'copy')),
          if (_canPin && !e.redacted)
            ListTile(leading: Icon(pinned ? Icons.push_pin : Icons.push_pin_outlined), title: Text(pinned ? 'Открепить' : 'Закрепить'), onTap: () => Navigator.pop(c, 'pin')),
          if (canSaveMedia(disp) && (!(Platform.isAndroid || Platform.isIOS) || isImg || disp.messageType == MessageTypes.Video))
            ListTile(leading: const Icon(Icons.download_rounded), title: Text(saveMediaLabel), onTap: () => Navigator.pop(c, 'save')),
          if (isImg && !e.redacted) ListTile(leading: const Icon(Icons.emoji_emotions_outlined), title: const Text('В мои стикеры'), onTap: () => Navigator.pop(c, 'sticker')),
          if (disp.hasAttachment && !isImg && !e.redacted) ListTile(leading: const Icon(Icons.download_outlined), title: const Text('Открыть файл'), onTap: () => Navigator.pop(c, 'open')),
          if (e.canRedact && !e.redacted)
            ListTile(
              leading: const Icon(Icons.delete_outline, color: Colors.redAccent),
              title: Text(mine ? 'Удалить' : 'Удалить у всех', style: const TextStyle(color: Colors.redAccent)),
              onTap: () => Navigator.pop(c, 'del'),
            ),
        ]),
      ),
    );
    if (a == null) return;
    if (a.startsWith('react:')) return _react(e, a.substring(6));
    switch (a) {
      case 'reply':
        _set(() {
          _editing = null;
          _replyTo = e;
        });
        _focus.requestFocus();
      case 'edit':
        _set(() {
          _replyTo = null;
          _editing = e;
          _text.text = disp.body;
        });
        _focus.requestFocus();
      case 'copy':
        await copySensitive(disp.calcUnlocalizedBody(hideReply: true));
        _toast('Текст скопирован (буфер очистится через минуту)');
      case 'thread':
        if (mounted) await Navigator.of(context).push(MaterialPageRoute(builder: (_) => ThreadPage(room: room, root: e)));
      case 'readers':
        await _showReaders(e);
      case 'history':
        await _showEditHistory(e, tl);
      case 'forward':
        await forwardEvents(context, _albums[e.eventId] ?? [e], tl);
      case 'select':
        _toggleSel(e);
      case 'endpoll':
        try {
          await endPoll(room, e);
        } catch (_) {
          _toast('Не получилось');
        }
      case 'pin':
        await _togglePin(e);
      case 'sticker':
        _toast(await addToOwnPack(disp));
      case 'open':
        await openAttachment(disp, _toast, context: context);
      case 'save':
        if (mounted) await saveMedia(context, disp);
      case 'del':
        final ok = await showDialog<bool>(
          context: context,
          builder: (d) => AlertDialog(
            title: Text((_albums[e.eventId]?.length ?? 1) > 1 ? 'Удалить альбом?' : 'Удалить сообщение?'),
            content: const Text('Сообщение удалится у всех участников чата.'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Отмена')),
              TextButton(onPressed: () => Navigator.pop(d, true), child: const Text('Удалить', style: TextStyle(color: Colors.redAccent))),
            ],
          ),
        );
        if (ok == true) {
          for (final m in _albums[e.eventId] ?? [e]) {
            if (m.canRedact && !m.redacted) await m.redactEvent();
          }
        }
    }
  }

  /// Кто прочитал сообщение (по отметкам о прочтении: прочитано всё до отметки).
  Future<void> _showReaders(Event e) async {
    final ts = e.originServerTs.millisecondsSinceEpoch;
    final readers = <(User, DateTime)>[];
    for (final MapEntry(key: uid, value: r) in room.receiptState.global.otherUsers.entries) {
      if (uid == client.userID || r.ts < ts) continue;
      readers.add((room.unsafeGetUserFromMemoryOrFallback(uid), DateTime.fromMillisecondsSinceEpoch(r.ts)));
    }
    readers.sort((a, b) => a.$2.compareTo(b.$2));
    final members = room.summary.mJoinedMemberCount ?? 0;
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (c) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(readers.isEmpty ? 'Пока никто не прочитал' : 'Прочитали: ${readers.length}${members > 1 ? ' из ${members - 1}' : ''}',
              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
          const SizedBox(height: 6),
          Flexible(
            child: ListView(shrinkWrap: true, children: [
              for (final (u, at) in readers)
                ListTile(
                  leading: Avatar(mxc: u.avatarUrl, name: u.calcDisplayname(), size: 40),
                  title: Text(u.calcDisplayname()),
                  trailing: Text(DateFormat('d MMM, HH:mm', 'ru').format(at), style: TextStyle(color: Theme.of(c).hintColor, fontSize: 12.5)),
                ),
            ]),
          ),
          const SizedBox(height: 8),
        ]),
      ),
    );
  }

  /// Все версии изменённого сообщения: исходная и каждая правка со временем.
  Future<void> _showEditHistory(Event e, Timeline tl) async {
    final edits = e.aggregatedEvents(tl, RelationshipTypes.edit).toList()..sort((a, b) => a.originServerTs.compareTo(b.originServerTs));
    String textOf(Event x) {
      final nc = x.content.tryGetMap<String, Object?>('m.new_content');
      return stripMarkdown('${nc?['body'] ?? x.body}');
    }

    final versions = [(e.originServerTs, stripMarkdown(e.calcUnlocalizedBody(hideReply: true)), 'Исходное'), for (final x in edits) (x.originServerTs, textOf(x), 'Правка')];
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (c) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(c).height * 0.7),
          child: ListView(shrinkWrap: true, padding: const EdgeInsets.fromLTRB(16, 0, 16, 16), children: [
            const Text('История правок', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 16)),
            for (final (at, text, kind) in versions.reversed)
              Container(
                margin: const EdgeInsets.only(top: 10),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(color: Theme.of(c).colorScheme.primary.withValues(alpha: 0.07), borderRadius: BorderRadius.circular(12)),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('$kind · ${DateFormat('d MMM, HH:mm', 'ru').format(at)}', style: TextStyle(color: Theme.of(c).hintColor, fontSize: 12.5)),
                  const SizedBox(height: 4),
                  SelectableText(text),
                ]),
              ),
          ]),
        ),
      ),
    );
  }

  /// Неотправленное сообщение: отправить сейчас или убрать.
  Future<void> _failedMenu(Event e) async {
    final a = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (c) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Padding(padding: EdgeInsets.only(bottom: 6), child: Text('Сообщение не отправлено — уйдёт само, когда появится связь', style: TextStyle(fontSize: 13.5))),
          ListTile(leading: const Icon(Icons.refresh_rounded), title: const Text('Отправить сейчас'), onTap: () => Navigator.pop(c, 'again')),
          ListTile(leading: const Icon(Icons.delete_outline, color: Colors.redAccent), title: const Text('Не отправлять', style: TextStyle(color: Colors.redAccent)), onTap: () => Navigator.pop(c, 'drop')),
        ]),
      ),
    );
    try {
      if (a == 'again') await e.sendAgain();
      if (a == 'drop') await e.cancelSend();
    } on FileNoLongerInCacheException {
      _toast('Файла уже нет в памяти — отправьте его заново');
    } catch (_) {
      _toast('Пока нет связи — отправится автоматически');
    }
  }
}
