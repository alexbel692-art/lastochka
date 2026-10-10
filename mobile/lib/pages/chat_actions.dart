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
    final a = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (c) => SafeArea(
        child: Wrap(alignment: WrapAlignment.spaceEvenly, children: [
          _attachBtn(c, Icons.photo_outlined, 'Фото', 'photo', Colors.blue),
          if (!isDesktop) _attachBtn(c, Icons.photo_camera_outlined, 'Камера', 'camera', Colors.pink),
          _attachBtn(c, Icons.insert_drive_file_outlined, 'Файл', 'file', Colors.teal),
          _attachBtn(c, Icons.videocam_outlined, 'Видео', 'video', Colors.indigo),
          if (canRecordRound) _attachBtn(c, Icons.radio_button_checked, 'Кружок', 'round', Colors.deepPurple),
          _attachBtn(c, Icons.poll_outlined, 'Опрос', 'poll', Colors.orange),
        ]),
      ),
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

  Widget _attachBtn(BuildContext c, IconData i, String label, String v, Color color) => InkWell(
        onTap: () => Navigator.pop(c, v),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            CircleAvatar(radius: 28, backgroundColor: color, child: Icon(i, color: Colors.white, size: 28)),
            const SizedBox(height: 6),
            Text(label),
          ]),
        ),
      );

}
