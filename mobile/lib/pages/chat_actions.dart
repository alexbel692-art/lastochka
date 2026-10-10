part of 'chat.dart';

// Отправка: текст, файлы, упоминания, отложенные, выбор сообщений, вложения.
extension _ChatActions on _ChatPageState {

  Future<void> _pasteFromClipboard() async {
    try {
      final files = await Pasteboard.files();
      if (files.isNotEmpty) {
        await _sendPaths(files);
        return;
      }
      final img = await Pasteboard.image;
      if (img == null || img.isEmpty) return;
      // текст из буфера уже вставлен — картинку отправляем, только если текста там не было
      final text = await Clipboard.getData(Clipboard.kTextPlain);
      if ((text?.text ?? '').isNotEmpty) return;
      if (!mounted) return;
      if (!await _confirmSend('Отправить картинку из буфера обмена?')) return;
      final clean = await cleanPhoto(img, 'Картинка.png');
      await room.sendFileEvent(MatrixImageFile(bytes: clean.bytes, name: clean.name, width: clean.width, height: clean.height), extraContent: ttlExtra(room));
      _toBottom();
    } catch (_) {}
  }

  Future<bool> _confirmSend(String title, [List<String> names = const []]) async =>
      await showDialog<bool>(
        context: context,
        builder: (d) => AlertDialog(
          title: Text(title),
          content: names.isEmpty ? null : Text(names.take(8).join('\n') + (names.length > 8 ? '\n… и ещё ${names.length - 8}' : '')),
          actions: [
            TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Отмена')),
            FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('Отправить')),
          ],
        ),
      ) ==
      true;

  Future<void> _sendPaths(List<String> paths) async {
    final files = paths.map(File.new).where((f) => f.existsSync()).toList();
    if (files.isEmpty || !mounted) return;
    final names = files.map((f) => p.basename(f.path)).toList();
    if (!await _confirmSend(files.length == 1 ? 'Отправить файл?' : 'Отправить файлы (${files.length})?', names)) return;
    final reply = _replyTo;
    _set(() => _replyTo = null);
    var failed = 0;
    for (final f in files) {
      try {
        final name = p.basename(f.path);
        final bytes = await f.readAsBytes();
        final lower = name.toLowerCase();
        if (RegExp(r'\.(jpe?g|png|webp)$').hasMatch(lower)) {
          final clean = await cleanPhoto(bytes, name);
          await room.sendFileEvent(MatrixImageFile(bytes: clean.bytes, name: clean.name, width: clean.width, height: clean.height), inReplyTo: reply, extraContent: ttlExtra(room));
        } else if (RegExp(r'\.(mp4|mov|m4v)$').hasMatch(lower)) {
          // видео — без места съёмки; не получилось очистить — не отправляем
          final clean = await cleanVideo(bytes);
          if (clean == null) throw StateError('video');
          await room.sendFileEvent(MatrixFile.fromMimeType(bytes: clean, name: name), inReplyTo: reply, extraContent: ttlExtra(room));
        } else {
          await room.sendFileEvent(MatrixFile.fromMimeType(bytes: bytes, name: name), inReplyTo: reply, extraContent: ttlExtra(room));
        }
      } catch (_) {
        failed++;
      }
    }
    if (failed > 0) _toast('Не отправлено файлов: $failed');
    _toBottom();
  }

  void _cancelBar() {
    if (_editing != null) _text.clear();
    _set(() {
      _replyTo = null;
      _editing = null;
    });
  }

  Future<void> _send() async {
    final t = _text.text.trim();
    if (t.isEmpty) return;
    final mentions = _activeMentions(t);
    _text.clear();
    final reply = _replyTo, edit = _editing;
    if (edit == null) Drafts.instance.set(room.id, '');
    _set(() {
      _replyTo = null;
      _editing = null;
      _mentionHits = [];
    });
    room.setTyping(false).catchError((_) {});
    try {
      final content = textContent(t, mentions: mentions);
      if (edit != null) {
        await room.sendEvent(content, editEventId: edit.eventId);
      } else {
        await room.sendEvent({...content, ...ttlExtra(room)}, inReplyTo: reply);
      }
    } catch (_) {
      _toast('Сообщение не отправлено');
    }
    _toBottom();
  }

  Map<String, String> _activeMentions(String t) {
    final m = Map.fromEntries(_mentions.entries.where((e) => t.contains(e.key)));
    _mentions.clear();
    return m;
  }

  // ---------- упоминания @ ----------
  void _updateMentionHits() {
    if (room.isDirectChat) return;
    final sel = _text.selection;
    final pos = sel.isValid ? sel.baseOffset : _text.text.length;
    final before = _text.text.substring(0, pos.clamp(0, _text.text.length));
    final m = RegExp(r'(?:^|\s)@([^\s@]{0,30})$').firstMatch(before);
    if (m == null) {
      if (_mentionHits.isNotEmpty) _mentionHits = [];
      return;
    }
    final q = m[1]!.toLowerCase();
    _mentionHits = room
        .getParticipants([Membership.join])
        .where((u) => u.id != client.userID && (u.calcDisplayname().toLowerCase().contains(q) || u.id.toLowerCase().contains(q)))
        .take(6)
        .toList();
  }

  void _insertMention(User u) {
    final name = u.calcDisplayname();
    final sel = _text.selection;
    final pos = sel.isValid ? sel.baseOffset : _text.text.length;
    final t = _text.text;
    final at = t.substring(0, pos).lastIndexOf('@');
    if (at < 0) return;
    final next = '${t.substring(0, at)}$name ${t.substring(pos)}';
    _mentions[name] = u.id;
    _text.value = TextEditingValue(text: next, selection: TextSelection.collapsed(offset: at + name.length + 1));
    _set(() => _mentionHits = []);
  }

  // ---------- отложенная отправка ----------
  Future<void> _schedule() async {
    final t = _text.text.trim();
    if (t.isEmpty || _editing != null) return;
    final now = DateTime.now();
    final day = await showDatePicker(context: context, initialDate: now, firstDate: now, lastDate: now.add(const Duration(days: 365)), helpText: 'Когда отправить');
    if (day == null || !mounted) return;
    final tm = await showTimePicker(context: context, initialTime: TimeOfDay.fromDateTime(now.add(const Duration(hours: 1))), helpText: 'Во сколько');
    if (tm == null || !mounted) return;
    final at = DateTime(day.year, day.month, day.day, tm.hour, tm.minute);
    if (!at.isAfter(DateTime.now())) return _toast('Выберите время в будущем');
    await Scheduler.instance.add(room, t, at, _activeMentions(t));
    _text.clear();
    Drafts.instance.set(room.id, '');
    _toast('Отправится ${DateFormat('d MMMM в HH:mm', 'ru').format(at)}. Ласточка должна быть запущена (можно свёрнутой)');
  }

  Future<void> _showScheduled() async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (c) => ValueListenableBuilder(
        valueListenable: Scheduler.instance.items,
        builder: (c, _, __) {
          final list = Scheduler.instance.forRoom(room.id);
          if (list.isEmpty) return const SizedBox(height: 120, child: Center(child: Text('Отложенных сообщений нет')));
          return SafeArea(
            child: ListView(shrinkWrap: true, children: [
              const Padding(padding: EdgeInsets.fromLTRB(16, 0, 16, 8), child: Text('Отложенные сообщения', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600))),
              for (final s in list)
                ListTile(
                  leading: const Icon(Icons.schedule_send_outlined),
                  title: Text(stripMarkdown(s.text), maxLines: 2, overflow: TextOverflow.ellipsis),
                  subtitle: Text(DateFormat('d MMMM, HH:mm', 'ru').format(s.at)),
                  trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                    IconButton(tooltip: 'Отправить сейчас', icon: const Icon(Icons.send), onPressed: () => Scheduler.instance.sendNow(s.id).catchError((_) => _toast('Не отправлено'))),
                    IconButton(tooltip: 'Удалить', icon: const Icon(Icons.delete_outline), onPressed: () => Scheduler.instance.remove(s.id)),
                  ]),
                ),
            ]),
          );
        },
      ),
    );
  }

  // ---------- выбор нескольких сообщений ----------
  void _toggleSel(Event e) {
    final s = _sel ?? <String>{};
    s.contains(e.eventId) ? s.remove(e.eventId) : s.add(e.eventId);
    _set(() => _sel = s.isEmpty ? null : s);
  }

  List<Event> get _selectedEvents => _events.where((e) => _sel?.contains(e.eventId) == true).toList();

  Future<void> _selCopy() async {
    final tl = _tl;
    final list = _selectedEvents..sort((a, b) => a.originServerTs.compareTo(b.originServerTs));
    final text = list.map((e) {
      final d = tl == null ? e : e.getDisplayEvent(tl);
      return '${e.senderFromMemoryOrFallback.calcDisplayname()}, ${DateFormat('d.MM HH:mm').format(e.originServerTs)}:\n${d.calcUnlocalizedBody(hideReply: true)}';
    }).join('\n\n');
    await copySensitive(text);
    _set(() => _sel = null);
    _toast('Скопировано (буфер очистится через минуту)');
  }

  Future<void> _selDelete() async {
    final list = _selectedEvents.where((e) => e.canRedact && !e.redacted).toList();
    if (list.isEmpty) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text('Удалить ${list.length} ${_plural(list.length, 'сообщение', 'сообщения', 'сообщений')}?'),
        content: const Text('Сообщения удалятся у всех участников чата.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Отмена')),
          TextButton(onPressed: () => Navigator.pop(d, true), child: const Text('Удалить', style: TextStyle(color: Colors.redAccent))),
        ],
      ),
    );
    if (ok != true) return;
    _set(() => _sel = null);
    for (final e in list) {
      try {
        await e.redactEvent();
      } catch (_) {}
    }
  }

  void _toBottom() {
    if (_scroll.hasClients) _scroll.animateTo(0, duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
  }

  Future<void> _attach() async {
    final items = <_AttachItem>[
      const _AttachItem(Icons.photo_library_rounded, 'Галерея', 'photo', [Color(0xFF4FA3FF), Color(0xFF2A6FE0)]),
      if (!isDesktop) const _AttachItem(Icons.photo_camera_rounded, 'Камера', 'camera', [Color(0xFFFF6B8B), Color(0xFFE5395F)]),
      const _AttachItem(Icons.movie_rounded, 'Видео', 'video', [Color(0xFF8E7BFF), Color(0xFF5B45E0)]),
      if (canRecordRound) const _AttachItem(Icons.radio_button_checked_rounded, 'Кружок', 'round', [Color(0xFFB36BFF), Color(0xFF8333E0)]),
      const _AttachItem(Icons.description_rounded, 'Файл', 'file', [Color(0xFF3DD6B0), Color(0xFF14A386)]),
      const _AttachItem(Icons.bar_chart_rounded, 'Опрос', 'poll', [Color(0xFFFFB547), Color(0xFFF08A1C)]),
    ];
    final a = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      elevation: 0,
      builder: (c) => _AttachSheet(items: items),
    );
    final reply = _replyTo;
    try {
      if (a == 'photo' || a == 'camera') {
        // imageQuality — чтобы HEIC с iPhone и Android пришёл как JPEG, который можно очистить
        final x = await ImagePicker().pickImage(source: a == 'camera' ? ImageSource.camera : ImageSource.gallery, imageQuality: 95, requestFullMetadata: false);
        if (x == null) return;
        // без места съёмки, модели телефона и прочих скрытых сведений
        final CleanImage clean;
        try {
          clean = await cleanPhoto(await x.readAsBytes(), x.name);
        } catch (_) {
          return _toast('Не удалось убрать из фото скрытые сведения (место съёмки и др.) — фото не отправлено');
        }
        _set(() => _replyTo = null);
        await room.sendFileEvent(
          MatrixImageFile(bytes: clean.bytes, name: clean.name, width: clean.width, height: clean.height),
          inReplyTo: reply,
          extraContent: ttlExtra(room),
        );
      } else if (a == 'video') {
        final err = await pickAndSendVideo(room, inReplyTo: reply);
        if (err != null) _toast(err);
        _set(() => _replyTo = null);
      } else if (a == 'round') {
        _set(() => _replyTo = null);
        final err = await recordRound(room, inReplyTo: reply);
        if (err != null) _toast(err);
      } else if (a == 'poll') {
        await createPoll(context, room);
      } else if (a == 'file') {
        final f = await FilePicker.pickFile();
        if (f == null) return;
        final bytes = await f.readAsBytes();
        _set(() => _replyTo = null);
        await room.sendFileEvent(MatrixFile.fromMimeType(bytes: bytes, name: f.name), inReplyTo: reply, extraContent: ttlExtra(room));
      }
      _toBottom();
    } catch (e) {
      _toast('Не отправлено: ${e is MatrixException ? e.errorMessage : 'ошибка сети'}');
    }
  }


}

class _AttachItem {
  final IconData icon;
  final String label, value;
  final List<Color> colors;
  const _AttachItem(this.icon, this.label, this.value, this.colors);
}

/// Меню «Прикрепить»: плавающая карточка с плитками-градиентами, плитки появляются по очереди.
class _AttachSheet extends StatelessWidget {
  final List<_AttachItem> items;
  const _AttachSheet({required this.items});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final dark = t.brightness == Brightness.dark;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
        child: Material(
          color: dark ? const Color(0xFF1F2329) : Colors.white,
          elevation: 12,
          shadowColor: Colors.black38,
          borderRadius: BorderRadius.circular(26),
          clipBehavior: Clip.antiAlias,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 18),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Container(width: 38, height: 4, decoration: BoxDecoration(color: t.hintColor.withValues(alpha: 0.35), borderRadius: BorderRadius.circular(2))),
              const SizedBox(height: 12),
              Text('Прикрепить', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: t.textTheme.titleMedium?.color)),
              const SizedBox(height: 16),
              LayoutBuilder(builder: (_, c) {
                final cols = c.maxWidth >= 520 ? 6 : 3;
                final w = c.maxWidth / cols;
                return Wrap(children: [
                  for (var i = 0; i < items.length; i++) SizedBox(width: w, child: _AttachTile(item: items[i], index: i)),
                ]);
              }),
            ]),
          ),
        ),
      ),
    );
  }
}

class _AttachTile extends StatelessWidget {
  final _AttachItem item;
  final int index;
  const _AttachTile({required this.item, required this.index});

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: 1),
        duration: Duration(milliseconds: 260 + index * 45),
        curve: Curves.easeOutBack,
        builder: (_, v, child) => Opacity(opacity: v.clamp(0.0, 1.0), child: Transform.scale(scale: 0.7 + 0.3 * v, child: child)),
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: () => Navigator.pop(context, item.value),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Container(
                width: 60,
                height: 60,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(20),
                  gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: item.colors),
                  boxShadow: [BoxShadow(color: item.colors.last.withValues(alpha: 0.35), blurRadius: 12, offset: const Offset(0, 5))],
                ),
                child: Icon(item.icon, color: Colors.white, size: 30),
              ),
              const SizedBox(height: 8),
              Text(item.label, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w500)),
            ]),
          ),
        ),
      );
}
