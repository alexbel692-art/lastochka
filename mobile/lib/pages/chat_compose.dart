part of 'chat.dart';

// Части экрана: панель выбора, сообщение в ленте, закреп, предупреждение о ключах, поле ввода.
extension _ChatCompose on _ChatPageState {
  PreferredSizeWidget _selBar(BuildContext context) {
    final list = _selectedEvents;
    final canDel = list.isNotEmpty && list.every((e) => e.canRedact && !e.redacted);
    return AppBar(
      leading: IconButton(tooltip: 'Отмена', icon: const Icon(Icons.close), onPressed: () => _set(() => _sel = null)),
      title: Text('Выбрано: ${list.length}'),
      actions: [
        if (list.any(canForward))
          IconButton(
            tooltip: 'Переслать',
            icon: const Icon(Icons.forward_outlined),
            onPressed: () async {
              await forwardEvents(context, list, _tl);
              if (mounted) _set(() => _sel = null);
            },
          ),
        IconButton(tooltip: 'Копировать', icon: const Icon(Icons.copy), onPressed: _selCopy),
        if (canDel) IconButton(tooltip: 'Удалить', icon: const Icon(Icons.delete_outline), onPressed: _selDelete),
      ],
    );
  }

  Widget _item(List<Event> events, int i, Timeline tl) {
    final e = events[i];
    final older = i + 1 < events.length ? events[i + 1] : null;
    final newer = i > 0 ? events[i - 1] : null;
    final newDay = older == null || !DateUtils.isSameDay(older.originServerTs, e.originServerTs);
    final serviceText = memberText(e) ?? ttlChangeText(e);
    final service = serviceText != null;
    bool sameGroup(Event? a) =>
        a != null && a.senderId == e.senderId && memberText(a) == null && a.originServerTs.difference(e.originServerTs).inMinutes.abs() < 10 && DateUtils.isSameDay(a.originServerTs, e.originServerTs);
    final firstOfGroup = newDay || !sameGroup(older);
    final lastOfGroup = !sameGroup(newer);
    final key = _keys.putIfAbsent(e.eventId, GlobalKey.new);
    return Column(key: key, children: [
      if (newDay) _DayChip(e.originServerTs),
      if (service)
        _ServiceChip(serviceText)
      else
        _SwipeToReply(
          onReply: () {
            _set(() {
              _editing = null;
              _replyTo = e;
            });
            _focus.requestFocus();
          },
          child: GestureDetector(
            onTap: _sel != null ? () => _toggleSel(e) : null,
            onLongPress: () => _sel != null ? _toggleSel(e) : _actions(e),
            onSecondaryTap: () => _actions(e),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 400),
              color: _flash == e.eventId || _sel?.contains(e.eventId) == true ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.18) : Colors.transparent,
              child: AbsorbPointer(
                absorbing: _sel != null,
                child: _Bubble(
                event: e,
                timeline: tl,
                room: room,
                showName: firstOfGroup && !room.isDirectChat,
                tail: lastOfGroup,
                showAvatar: !room.isDirectChat && lastOfGroup,
                avatarSpace: !room.isDirectChat,
                onReact: (k) => _react(e, k),
                onReplyTap: _jumpTo,
              ),
              ),
            ),
          ),
        ),
    ]);
  }

  Widget _pinBar(BuildContext context) {
    final ids = room.pinnedEventIds;
    if (ids.isEmpty) return const SizedBox.shrink();
    var idx = _pinIdx < 0 || _pinIdx >= ids.length ? ids.length - 1 : _pinIdx;
    final id = ids[idx];
    final accent = Theme.of(context).colorScheme.primary;
    return Material(
      color: Theme.of(context).scaffoldBackgroundColor,
      elevation: 0.5,
      child: InkWell(
        onTap: () {
          _jumpTo(id);
          _set(() => _pinIdx = idx == 0 ? ids.length - 1 : idx - 1);
        },
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
          child: Row(children: [
            Column(mainAxisSize: MainAxisSize.min, children: [
              for (var k = 0; k < min(ids.length, 4); k++)
                Container(
                  width: 2.5,
                  height: ids.length > 1 ? 34 / min(ids.length, 4) - 2 : 34,
                  margin: const EdgeInsets.symmetric(vertical: 1),
                  color: (ids.length > 4 ? k == 3 - (ids.length - 1 - idx).clamp(0, 3) : k == idx) ? accent : accent.withValues(alpha: 0.3),
                ),
            ]),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                Text(ids.length > 1 ? 'Закреплённое сообщение #${idx + 1}' : 'Закреплённое сообщение',
                    style: TextStyle(color: accent, fontWeight: FontWeight.w600, fontSize: 13.5)),
                FutureBuilder<Event?>(
                  future: room.getEventById(id),
                  builder: (_, s) => Text(
                    s.data == null ? (s.connectionState == ConnectionState.done ? 'Сообщение недоступно' : 'Загрузка…') : eventPreview(s.data!, _tl),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 14),
                  ),
                ),
              ]),
            ),
            if (_canPin)
              IconButton(
                tooltip: 'Открепить',
                icon: Icon(Icons.close, size: 20, color: Theme.of(context).hintColor),
                onPressed: () async {
                  final list = List<String>.from(ids)..remove(id);
                  try {
                    await room.setPinnedEvents(list);
                  } catch (_) {}
                },
              ),
          ]),
        ),
      ),
    );
  }

  /// Ключи собеседника сменились — предупреждаем и не даём писать, пока вы не решите, как быть.
  Widget? _identityBanner(BuildContext context) {
    final who = Trust.instance.changedIn(room);
    if (who.isEmpty) return null;
    final uid = who.first;
    final wasVerified = Trust.instance.changed.value[uid] == true;
    final name = room.unsafeGetUserFromMemoryOrFallback(uid).calcDisplayname();
    final color = wasVerified ? Colors.red : Colors.orange.shade800;
    return Material(
      color: color.withValues(alpha: 0.12),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 8),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
            Row(children: [
              Icon(Icons.gpp_bad_outlined, color: color),
              const SizedBox(width: 10),
              Expanded(child: Text('У $name сменились ключи безопасности', style: TextStyle(fontWeight: FontWeight.w700, color: color))),
            ]),
            const SizedBox(height: 4),
            Text(
              wasVerified
                  ? 'Вы подтверждали этого собеседника, а теперь его ключи другие. Так бывает после сброса аккаунта — или при попытке перехвата переписки. Уточните у него лично или подтвердите заново.'
                  : 'Так бывает после сброса аккаунта или входа без ключа восстановления — или при попытке перехвата. Если сомневаетесь, уточните у собеседника лично и подтвердите его.',
              style: const TextStyle(fontSize: 13.5),
            ),
            const SizedBox(height: 6),
            Wrap(spacing: 8, alignment: WrapAlignment.end, children: [
              TextButton(
                onPressed: () async {
                  await Trust.instance.acceptChange(uid);
                  if (mounted) _set(() {});
                },
                child: const Text('Понятно, продолжить'),
              ),
              FilledButton(
                onPressed: () => verifyUser(context, uid),
                child: const Text('Подтвердить'),
              ),
            ]),
          ]),
        ),
      ),
    );
  }

  /// Меню выделенного текста: оформление, как в Telegram.
  Widget _formatMenu(BuildContext context, EditableTextState st) {
    final sel = _text.selection;
    void wrap(String l, [String? r]) {
      final t = _text.text;
      final s0 = sel.start, s1 = sel.end;
      final inner = t.substring(s0, s1);
      final next = '${t.substring(0, s0)}$l$inner${r ?? l}${t.substring(s1)}';
      _text.value = TextEditingValue(text: next, selection: TextSelection(baseOffset: s0 + l.length, extentOffset: s1 + l.length));
      st.hideToolbar();
    }

    final items = [
      ...st.contextMenuButtonItems,
      if (sel.isValid && !sel.isCollapsed) ...[
        ContextMenuButtonItem(label: 'Жирный', onPressed: () => wrap('**')),
        ContextMenuButtonItem(label: 'Курсив', onPressed: () => wrap('__')),
        ContextMenuButtonItem(label: 'Зачёркнутый', onPressed: () => wrap('~~')),
        ContextMenuButtonItem(label: 'Моноширинный', onPressed: () => wrap('`')),
        ContextMenuButtonItem(label: 'Скрытый', onPressed: () => wrap('||')),
      ],
    ];
    return AdaptiveTextSelectionToolbar.buttonItems(anchors: st.contextMenuAnchors, buttonItems: items);
  }

  Widget _composer(BuildContext context) {
    final bg = Theme.of(context).scaffoldBackgroundColor;
    final accent = Theme.of(context).colorScheme.primary;
    final hint = Theme.of(context).hintColor;
    final bar = _editing ?? _replyTo;
    final empty = _text.text.trim().isEmpty;
    final blocked = _identityBanner(context);
    if (blocked != null) return blocked;
    return Material(
      color: bg,
      child: SafeArea(
        top: false,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          if (_mentionHits.isNotEmpty)
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 220),
              child: ListView(shrinkWrap: true, padding: EdgeInsets.zero, children: [
                for (final u in _mentionHits)
                  ListTile(
                    dense: true,
                    leading: Avatar(mxc: u.avatarUrl, name: u.calcDisplayname(), size: 32),
                    title: Text(u.calcDisplayname()),
                    subtitle: Text(u.id, style: TextStyle(color: hint, fontSize: 12)),
                    onTap: () => _insertMention(u),
                  ),
              ]),
            ),
          ValueListenableBuilder(
            valueListenable: Scheduler.instance.items,
            builder: (_, __, ___) {
              final n = Scheduler.instance.forRoom(room.id).length;
              if (n == 0) return const SizedBox.shrink();
              return InkWell(
                onTap: _showScheduled,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(14, 6, 14, 2),
                  child: Row(children: [
                    Icon(Icons.schedule_send_outlined, size: 18, color: accent),
                    const SizedBox(width: 8),
                    Text('Отложенных сообщений: $n', style: TextStyle(color: accent, fontSize: 13.5)),
                  ]),
                ),
              );
            },
          ),
          if (bar != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 6, 4, 0),
              child: Row(children: [
                Icon(_editing != null ? Icons.edit_outlined : Icons.reply, color: accent),
                const SizedBox(width: 10),
                Container(width: 2, height: 34, color: accent),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                    Text(_editing != null ? 'Редактирование' : bar.senderFromMemoryOrFallback.calcDisplayname(),
                        style: TextStyle(color: accent, fontWeight: FontWeight.w600, fontSize: 13.5)),
                    Text(eventPreview(bar, _tl), maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14)),
                  ]),
                ),
                IconButton(icon: Icon(Icons.close, color: hint), onPressed: _cancelBar),
              ]),
            ),
          if (_recording)
            SizedBox(
              height: 56,
              child: Row(children: [
                const SizedBox(width: 16),
                const _Blink(),
                const SizedBox(width: 10),
                Text(fmtDur(_rec.elapsedMs), style: const TextStyle(fontSize: 16, fontFeatures: [FontFeature.tabularFigures()])),
                const Spacer(),
                TextButton(onPressed: () => _stopRec(send: false), child: const Text('Отмена')),
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: IconButton.filled(onPressed: () => _stopRec(send: true), icon: const Icon(Icons.arrow_upward)),
                ),
              ]),
            )
          else
            Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
              IconButton(
                tooltip: 'Эмодзи и стикеры',
                icon: Icon(_panel ? Icons.keyboard_outlined : Icons.emoji_emotions_outlined, color: hint),
                onPressed: () {
                  if (_panel) {
                    _set(() => _panel = false);
                    _focus.requestFocus();
                  } else {
                    FocusScope.of(context).unfocus();
                    _set(() => _panel = true);
                  }
                },
              ),
              Expanded(
                child: TextField(enableIMEPersonalizedLearning: false, 
                  controller: _text,
                  focusNode: _focus,
                  minLines: 1,
                  maxLines: 6,
                  onTap: () => _panel ? _set(() => _panel = false) : null,
                  textCapitalization: TextCapitalization.sentences,
                  keyboardType: TextInputType.multiline,
                  contextMenuBuilder: _formatMenu,
                  decoration: InputDecoration(
                    hintText: roomTtl(room) > 0 ? '🔥 Исчезнет через ${ttlText(roomTtl(room)).replaceFirst('1 ', '')}' : 'Сообщение',
                    filled: false,
                    border: InputBorder.none,
                    contentPadding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                ),
              ),
              if (empty && _editing == null) IconButton(tooltip: 'Прикрепить', icon: Icon(Icons.attach_file, color: hint), onPressed: _attach),
              if (empty && _editing == null)
                IconButton(tooltip: 'Голосовое сообщение', icon: Icon(Icons.mic_none, color: hint), onPressed: _startRec)
              else
                // нажатие — отправить, долгое нажатие (правая кнопка мыши) — отправить позже
                InkWell(
                  customBorder: const CircleBorder(),
                  onTap: _send,
                  onLongPress: _editing == null ? _schedule : null,
                  onSecondaryTap: _editing == null ? _schedule : null,
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Icon(_editing != null ? Icons.check_circle : Icons.send, color: accent, semanticLabel: _editing != null ? 'Сохранить' : 'Отправить'),
                  ),
                ),
            ]),
          if (_panel && !_recording)
            EmojiStickerPanel(
              room: room,
              height: min(320, MediaQuery.sizeOf(context).height * 0.4),
              onEmoji: (em) {
                final s = _text.selection;
                final t = _text.text;
                final start = s.isValid ? s.start : t.length, end = s.isValid ? s.end : t.length;
                _text.value = TextEditingValue(text: t.replaceRange(start, end, em), selection: TextSelection.collapsed(offset: start + em.length));
              },
              onSticker: (st) async {
                final reply = _replyTo;
                _set(() {
                  _replyTo = null;
                  _panel = false;
                });
                try {
                  await sendSticker(room, st, inReplyTo: reply);
                  _toBottom();
                } catch (_) {
                  _toast('Стикер не отправлен');
                }
              },
            ),
        ]),
      ),
    );
  }
}
