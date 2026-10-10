part of 'chat.dart';

// Голосовые, реакции, закрепление, переход к сообщению, меню сообщения.
extension _ChatMessages on _ChatPageState {
  // ---------- голосовые ----------
  Future<void> _startRec() async {
    if (!await _rec.start()) return _toast('Нет доступа к микрофону');
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
          if (canForward(e)) ListTile(leading: const Icon(Icons.forward_outlined), title: const Text('Переслать'), onTap: () => Navigator.pop(c, 'forward')),
          ListTile(leading: const Icon(Icons.check_circle_outline), title: const Text('Выбрать'), onTap: () => Navigator.pop(c, 'select')),
          if (isPollStart(e) && !e.redacted && (mine || room.ownPowerLevel.level >= 50) && pollStateOf(e, tl) == null)
            ListTile(leading: const Icon(Icons.stop_circle_outlined), title: const Text('Завершить опрос'), onTap: () => Navigator.pop(c, 'endpoll')),
          if (mine && isText && !e.redacted) ListTile(leading: const Icon(Icons.edit_outlined), title: const Text('Изменить'), onTap: () => Navigator.pop(c, 'edit')),
          if (isText && !e.redacted) ListTile(leading: const Icon(Icons.copy), title: const Text('Копировать текст'), onTap: () => Navigator.pop(c, 'copy')),
          if (_canPin && !e.redacted)
            ListTile(leading: Icon(pinned ? Icons.push_pin : Icons.push_pin_outlined), title: Text(pinned ? 'Открепить' : 'Закрепить'), onTap: () => Navigator.pop(c, 'pin')),
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
      case 'forward':
        await forwardEvents(context, [e], tl);
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
        await openAttachment(disp, _toast);
      case 'del':
        final ok = await showDialog<bool>(
          context: context,
          builder: (d) => AlertDialog(
            title: const Text('Удалить сообщение?'),
            content: const Text('Сообщение удалится у всех участников чата.'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Отмена')),
              TextButton(onPressed: () => Navigator.pop(d, true), child: const Text('Удалить', style: TextStyle(color: Colors.redAccent))),
            ],
          ),
        );
        if (ok == true) await e.redactEvent();
    }
  }
}
