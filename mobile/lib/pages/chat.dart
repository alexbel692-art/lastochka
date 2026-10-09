import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:matrix/matrix.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as p;

import '../calls/voip.dart';
import '../chat/autodelete.dart';
import '../chat/stickers.dart';
import '../chat/voice.dart';
import '../main.dart';
import '../system/notify.dart';
import '../system/privacy.dart';
import '../system/trust.dart';
import 'verify.dart';
import '../theme.dart';
import '../widgets/avatar.dart';
import '../widgets/bubble_shape.dart';
import 'chats.dart';
import 'room_info.dart';

final bool isDesktop = Platform.isWindows || Platform.isMacOS || Platform.isLinux;
const quickReactions = ['👍', '❤️', '😂', '😮', '😢', '🙏', '🔥', '👏'];

class ChatPage extends StatefulWidget {
  final Room room;
  final bool embedded; // показан справа от списка чатов (планшет, компьютер)
  const ChatPage({super.key, required this.room, this.embedded = false});
  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  Room get room => widget.room;
  Timeline? _tl;
  final _text = TextEditingController();
  final _scroll = ScrollController();
  late final FocusNode _focus = FocusNode(onKeyEvent: _onKey);
  final Map<String, GlobalKey> _keys = {};
  StreamSubscription? _syncSub;
  Event? _replyTo, _editing;
  bool _loadingMore = false, _panel = false, _showDown = false;
  String? _flash;
  int _pinIdx = -1;
  // запись голосового
  final _rec = VoiceRecorder();
  Timer? _recTimer;
  bool get _recording => _rec.started != null;
  DateTime _typingSent = DateTime(2000);
  Timer? _ttlTick, _floatHide;
  // поиск по чату
  bool _searching = false;
  final _searchCtl = TextEditingController();
  List<String> _hits = [];
  int _hitIdx = 0;
  bool _searchingMore = false;
  // плавающая дата при прокрутке
  final _listKey = GlobalKey();
  DateTime? _floatDate;
  bool _floatShow = false;
  List<Event> _events = const [];

  @override
  void initState() {
    super.initState();
    openRoomId = room.id;
    clearRoomNotification(room.id);
    visibility.addListener(_onVisible);
    Trust.instance.changed.addListener(_onTrust);
    Trust.instance.senderChecks.addListener(_onTrust);
    _init();
    // исчезающие сообщения: раз в секунду обновляем таймеры и скрываем истёкшие
    _ttlTick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && (roomTtl(room) > 0 || _events.any((e) => expiryOf(e) > 0))) setState(() {});
    });
    _scroll.addListener(() {
      _updateFloatDate();
      if (_scroll.position.pixels > _scroll.position.maxScrollExtent - 600) _more();
      final down = _scroll.position.pixels > 400;
      if (down != _showDown) setState(() => _showDown = down);
    });
    _text.addListener(_onText);
    _syncSub = client.onSync.stream.where((s) => s.rooms?.join?.containsKey(room.id) == true).listen((_) {
      if (mounted) setState(() {});
    });
  }

  Future<void> _init() async {
    final tl = await room.getTimeline(onUpdate: () {
      if (mounted) setState(() {});
      _markRead();
    });
    if (!mounted) return tl.cancelSubscriptions();
    setState(() => _tl = tl);
    openTimelines.add(tl);
    if (tl.events.length < 30) await _more();
    _markRead();
  }

  void _onTrust() {
    if (mounted) setState(() {});
  }

  void _onVisible() {
    if (!appVisible) return;
    _markRead();
    clearRoomNotification(room.id);
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

  // отмечаем прочитанным, только когда чат действительно на экране
  void _markRead() {
    if (!appVisible) return;
    final last = _tl?.events.firstOrNull;
    if (last == null || room.notificationCount == 0 && room.fullyRead == last.eventId) return;
    room.setReadMarker(last.eventId, mRead: last.eventId).catchError((_) {});
  }

  void _onText() {
    setState(() {});
    if (_text.text.isNotEmpty && DateTime.now().difference(_typingSent).inSeconds > 4) {
      _typingSent = DateTime.now();
      room.setTyping(true, timeout: 6000).catchError((_) {});
    }
  }

  // На компьютере Enter отправляет, Shift+Enter — новая строка
  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (!isDesktop || e is! KeyDownEvent) return KeyEventResult.ignored;
    if ((e.logicalKey == LogicalKeyboardKey.enter || e.logicalKey == LogicalKeyboardKey.numpadEnter) && !HardwareKeyboard.instance.isShiftPressed) {
      _send();
      return KeyEventResult.handled;
    }
    if (e.logicalKey == LogicalKeyboardKey.escape && (_replyTo != null || _editing != null)) {
      _cancelBar();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  void dispose() {
    if (openRoomId == room.id) openRoomId = null;
    visibility.removeListener(_onVisible);
    Trust.instance.changed.removeListener(_onTrust);
    Trust.instance.senderChecks.removeListener(_onTrust);
    openTimelines.remove(_tl);
    _tl?.cancelSubscriptions();
    _syncSub?.cancel();
    _ttlTick?.cancel();
    _floatHide?.cancel();
    _recTimer?.cancel();
    _rec.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _toast(String s) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s), duration: const Duration(seconds: 2)));

  void _cancelBar() {
    if (_editing != null) _text.clear();
    setState(() {
      _replyTo = null;
      _editing = null;
    });
  }

  Future<void> _send() async {
    final t = _text.text.trim();
    if (t.isEmpty) return;
    _text.clear();
    final reply = _replyTo, edit = _editing;
    setState(() {
      _replyTo = null;
      _editing = null;
    });
    room.setTyping(false).catchError((_) {});
    try {
      final ttl = ttlExtra(room);
      if (edit != null) {
        await room.sendTextEvent(t, editEventId: edit.eventId);
      } else if (ttl.isNotEmpty) {
        await room.sendEvent({'msgtype': MessageTypes.Text, 'body': t, ...ttl}, inReplyTo: reply);
      } else {
        await room.sendTextEvent(t, inReplyTo: reply);
      }
    } catch (_) {
      _toast('Сообщение не отправлено');
    }
    _toBottom();
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
        ]),
      ),
    );
    final reply = _replyTo;
    try {
      if (a == 'photo' || a == 'camera') {
        final x = await ImagePicker().pickImage(source: a == 'camera' ? ImageSource.camera : ImageSource.gallery, imageQuality: 85, maxWidth: 2560);
        if (x == null) return;
        setState(() => _replyTo = null);
        await room.sendFileEvent(MatrixImageFile(bytes: await x.readAsBytes(), name: x.name), inReplyTo: reply, extraContent: ttlExtra(room));
      } else if (a == 'file') {
        final f = await FilePicker.pickFile();
        if (f == null) return;
        final bytes = await f.readAsBytes();
        setState(() => _replyTo = null);
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

  // ---------- поиск по чату ----------
  List<String> _collectHits(String q) {
    final s = q.trim().toLowerCase();
    final tl = _tl;
    if (s.length < 2 || tl == null) return [];
    final events = tl.events.where(_visible);
    return [
      for (final e in events)
        if (memberText(e) == null && ttlChangeText(e) == null && !e.redacted && eventPreview(e, tl).toLowerCase().contains(s)) e.eventId,
    ];
  }

  void _runSearch(String q) {
    final hits = _collectHits(q);
    setState(() {
      _hits = hits;
      _hitIdx = 0;
    });
    if (hits.isNotEmpty) _jumpTo(hits.first);
  }

  /// Перейти к следующему (+1, более старому) или предыдущему (−1) совпадению.
  Future<void> _hitStep(int d) async {
    if (_hits.isEmpty) return;
    var i = _hitIdx + d;
    if (i >= _hits.length) {
      // дальше — ищем в более старой истории
      final tl = _tl;
      if (tl == null || !tl.canRequestHistory || _searchingMore) return;
      setState(() => _searchingMore = true);
      final before = _hits.length;
      for (var k = 0; k < 5 && tl.canRequestHistory && _hits.length == before; k++) {
        await _more();
        if (!mounted) return;
        setState(() {});
        await Future.delayed(const Duration(milliseconds: 50));
        _hits = _collectHits(_searchCtl.text);
      }
      setState(() => _searchingMore = false);
      if (_hits.length == before) return;
      i = before;
    }
    if (i < 0) return;
    setState(() => _hitIdx = i);
    _jumpTo(_hits[i]);
  }

  void _closeSearch() {
    _searchCtl.clear();
    setState(() {
      _searching = false;
      _hits = [];
    });
  }

  Widget _searchBar(BuildContext context) {
    final q = _searchCtl.text.trim();
    return Material(
      color: Theme.of(context).scaffoldBackgroundColor,
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
        child: Row(children: [
          Expanded(
            child: Text(
              _searchingMore
                  ? 'Ищем в истории…'
                  : q.length < 2
                      ? 'Введите хотя бы 2 буквы'
                      : _hits.isEmpty
                          ? 'Ничего не найдено'
                          : '${_hitIdx + 1} из ${_hits.length}${_tl?.canRequestHistory == true ? '+' : ''}',
              style: TextStyle(color: Theme.of(context).hintColor),
            ),
          ),
          IconButton(tooltip: 'Раньше', icon: const Icon(Icons.keyboard_arrow_up), onPressed: q.length < 2 ? null : () => _hitStep(1)),
          IconButton(tooltip: 'Позже', icon: const Icon(Icons.keyboard_arrow_down), onPressed: _hitIdx > 0 ? () => _hitStep(-1) : null),
        ]),
      ),
    );
  }

  // ---------- плавающая дата ----------
  void _updateFloatDate() {
    final box = _listKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.attached) return;
    final top = box.localToGlobal(Offset.zero).dy;
    DateTime? best;
    var bestY = -1e9, minY = 1e9;
    DateTime? minDate;
    for (final e in _events) {
      final rb = _keys[e.eventId]?.currentContext?.findRenderObject() as RenderBox?;
      if (rb == null || !rb.attached) continue;
      final y = rb.localToGlobal(Offset.zero).dy - top;
      if (y <= 36 && y > bestY) {
        bestY = y;
        best = e.originServerTs;
      }
      if (y < minY) {
        minY = y;
        minDate = e.originServerTs;
      }
    }
    final d = best ?? minDate;
    if (d == null) return;
    _floatHide?.cancel();
    _floatHide = Timer(const Duration(milliseconds: 1400), () => mounted ? setState(() => _floatShow = false) : null);
    if (!_floatShow || _floatDate == null || !DateUtils.isSameDay(_floatDate, d)) {
      setState(() {
        _floatDate = d;
        _floatShow = _scroll.hasClients && _scroll.position.pixels > 40;
      });
    }
  }

  // ---------- голосовые ----------
  Future<void> _startRec() async {
    if (!await _rec.start()) return _toast('Нет доступа к микрофону');
    HapticFeedback.mediumImpact();
    _recTimer = Timer.periodic(const Duration(milliseconds: 200), (_) {
      if (mounted) setState(() {});
      if (_rec.elapsedMs > 15 * 60 * 1000) _stopRec(send: true);
    });
    setState(() {});
  }

  Future<void> _stopRec({required bool send}) async {
    _recTimer?.cancel();
    if (!send) {
      await _rec.cancel();
      return setState(() {});
    }
    final r = await _rec.stop();
    setState(() {});
    if (r == null) return _toast('Слишком короткое голосовое');
    final reply = _replyTo;
    setState(() => _replyTo = null);
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
        setState(() => _flash = id);
        Future.delayed(const Duration(milliseconds: 1200), () => mounted ? setState(() => _flash = null) : null);
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
        setState(() {
          _editing = null;
          _replyTo = e;
        });
        _focus.requestFocus();
      case 'edit':
        setState(() {
          _replyTo = null;
          _editing = e;
          _text.text = disp.body;
        });
        _focus.requestFocus();
      case 'copy':
        await Clipboard.setData(ClipboardData(text: disp.calcUnlocalizedBody(hideReply: true)));
        _toast('Текст скопирован');
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

  // Видимые события: сообщения, стикеры, вход/выход участников, звонки.
  bool _visible(Event e) {
    if (isExpired(e)) return false; // исчезнувшее сообщение
    if (ttlChangeText(e) != null) return true;
    if (e.relationshipType == RelationshipTypes.edit) return false;
    if (e.type == EventTypes.Message || e.type == EventTypes.Sticker || e.type == EventTypes.Encrypted) return true;
    if (e.type == EventTypes.CallInvite) return true;
    return memberText(e) != null;
  }

  String _subtitle() {
    final typing = room.typingUsers.where((u) => u.id != client.userID).toList();
    if (typing.isNotEmpty) {
      return room.isDirectChat ? 'печатает…' : '${typing.map((u) => u.calcDisplayname()).take(2).join(', ')} ${typing.length > 1 ? 'печатают' : 'печатает'}…';
    }
    if (room.isDirectChat) return room.encrypted ? 'защищённый чат' : 'личный чат';
    final n = room.summary.mJoinedMemberCount ?? room.getParticipants([Membership.join]).length;
    return '$n ${_plural(n, 'участник', 'участника', 'участников')}';
  }

  @override
  Widget build(BuildContext context) {
    final name = room.getLocalizedDisplayname();
    final tl = _tl;
    final events = tl?.events.where(_visible).toList() ?? const <Event>[];
    _events = events;
    final typing = room.typingUsers.any((u) => u.id != client.userID);
    final accent = Theme.of(context).colorScheme.primary;
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: !widget.embedded,
        titleSpacing: widget.embedded ? 16 : 0,
        title: _searching
            ? TextField(
                controller: _searchCtl,
                autofocus: true,
                textInputAction: TextInputAction.search,
                onChanged: _runSearch,
                onSubmitted: (_) => _hitStep(1),
                decoration: const InputDecoration(hintText: 'Поиск в чате', filled: false, border: InputBorder.none),
              )
            : InkWell(
          onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => RoomInfoPage(room: room))),
          child: Row(children: [
          Avatar(mxc: room.avatar, name: name, size: 40),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Flexible(child: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600))),
                if (room.isDirectChat && room.directChatMatrixID != null && Trust.instance.userVerified(room.directChatMatrixID!))
                  const Padding(padding: EdgeInsets.only(left: 4), child: Icon(Icons.verified_user, size: 16, color: Colors.green)),
                if (Trust.instance.changedIn(room).isNotEmpty)
                  const Padding(padding: EdgeInsets.only(left: 4), child: Icon(Icons.gpp_bad, size: 16, color: Colors.red)),
              ]),
              Text(_subtitle(), maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, color: typing ? accent : Theme.of(context).hintColor)),
            ]),
          ),
        ])),
        actions: _searching
            ? [IconButton(tooltip: 'Закрыть поиск', icon: const Icon(Icons.close), onPressed: _closeSearch)]
            : [
          IconButton(tooltip: 'Поиск в чате', icon: const Icon(Icons.search), onPressed: () => setState(() => _searching = true)),
          if (canCall(room)) ...[
            IconButton(icon: const Icon(Icons.call_outlined), tooltip: 'Аудиозвонок', onPressed: () => startCall(context, room, video: false)),
            IconButton(icon: const Icon(Icons.videocam_outlined), tooltip: 'Видеозвонок', onPressed: () => startCall(context, room, video: true)),
          ],
        ],
      ),
      body: LayoutBuilder(
        builder: (context, box) => _PaneWidth(
          width: box.maxWidth,
          child: Container(
            decoration: BoxDecoration(gradient: Bubbles.wallGradient(context)),
            child: Column(children: [
              _pinBar(context),
              Expanded(
                child: Stack(children: [
                  tl == null
                      ? const Center(child: CircularProgressIndicator())
                      : ListView.builder(
                          key: _listKey,
                          controller: _scroll,
                          reverse: true,
                          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
                          itemCount: events.length,
                          itemBuilder: (_, i) => _item(events, i, tl),
                        ),
                  // дата сверху при прокрутке, как в Telegram
                  if (_floatDate != null)
                    Positioned(
                      top: 0,
                      left: 0,
                      right: 0,
                      child: IgnorePointer(
                        child: AnimatedOpacity(
                          opacity: _floatShow ? 1 : 0,
                          duration: const Duration(milliseconds: 250),
                          child: _DayChip(_floatDate!),
                        ),
                      ),
                    ),
                  if (_searching) Positioned(left: 0, right: 0, bottom: 0, child: _searchBar(context)),
                  if (_showDown)
                    Positioned(
                      right: 12,
                      bottom: 12,
                      child: FloatingActionButton.small(
                        heroTag: null,
                        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
                        foregroundColor: Theme.of(context).hintColor,
                        onPressed: _toBottom,
                        child: const Icon(Icons.keyboard_arrow_down),
                      ),
                    ),
                ]),
              ),
              _composer(context),
            ]),
          ),
        ),
      ),
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
            setState(() {
              _editing = null;
              _replyTo = e;
            });
            _focus.requestFocus();
          },
          child: GestureDetector(
            onLongPress: () => _actions(e),
            onSecondaryTap: () => _actions(e),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 400),
              color: _flash == e.eventId ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.18) : Colors.transparent,
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
          setState(() => _pinIdx = idx == 0 ? ids.length - 1 : idx - 1);
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
                  if (mounted) setState(() {});
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
                    setState(() => _panel = false);
                    _focus.requestFocus();
                  } else {
                    FocusScope.of(context).unfocus();
                    setState(() => _panel = true);
                  }
                },
              ),
              Expanded(
                child: TextField(
                  controller: _text,
                  focusNode: _focus,
                  minLines: 1,
                  maxLines: 6,
                  onTap: () => _panel ? setState(() => _panel = false) : null,
                  textCapitalization: TextCapitalization.sentences,
                  keyboardType: TextInputType.multiline,
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
                IconButton(tooltip: _editing != null ? 'Сохранить' : 'Отправить', icon: Icon(_editing != null ? Icons.check_circle : Icons.send, color: accent), onPressed: _send),
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
                setState(() {
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

String _plural(int n, String one, String few, String many) {
  final m10 = n % 10, m100 = n % 100;
  if (m10 == 1 && m100 != 11) return one;
  if (m10 >= 2 && m10 <= 4 && (m100 < 12 || m100 > 14)) return few;
  return many;
}

/// Короткое описание сообщения (для ответа, закрепа, списка чатов).
String eventPreview(Event e, Timeline? tl) {
  final d = tl == null ? e : e.getDisplayEvent(tl);
  if (d.redacted) return 'Сообщение удалено';
  if (d.type == EventTypes.Encrypted) return '🔒 Зашифрованное сообщение';
  if (d.type == EventTypes.Sticker) return 'Стикер';
  return switch (d.messageType) {
    MessageTypes.Image => '🖼 Фото',
    MessageTypes.Video => '🎬 Видео',
    MessageTypes.Audio => d.content.containsKey('org.matrix.msc3245.voice') ? '🎤 Голосовое сообщение' : '🎵 ${d.body}',
    MessageTypes.File => '📎 ${d.body}',
    _ => d.calcUnlocalizedBody(hideReply: true).replaceAll('\n', ' '),
  };
}

/// Скачать вложение и открыть системной программой.
Future<void> openAttachment(Event e, void Function(String) toast) async {
  try {
    toast('Загрузка…');
    final f = await e.downloadAndDecryptAttachment();
    // расшифрованная копия — во внутренней папке приложения; удаляется при следующем запуске
    final dir = await privateTemp();
    var name = (e.content.tryGet<String>('filename') ?? e.body).replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    if (name.isEmpty) name = 'файл';
    final path = p.join(dir.path, name);
    await File(path).writeAsBytes(f.bytes, flush: true);
    final r = await OpenFilex.open(path);
    if (r.type != ResultType.done) toast('Нет программы, чтобы открыть этот файл');
  } catch (_) {
    toast('Не удалось скачать файл');
  }
}

class _SwipeToReply extends StatefulWidget {
  final Widget child;
  final VoidCallback onReply;
  const _SwipeToReply({required this.child, required this.onReply});
  @override
  State<_SwipeToReply> createState() => _SwipeToReplyState();
}

class _SwipeToReplyState extends State<_SwipeToReply> {
  double _dx = 0;
  bool _armed = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onHorizontalDragUpdate: (d) {
        final nx = (_dx + d.delta.dx).clamp(-80.0, 0.0);
        final armed = nx < -56;
        if (armed && !_armed) HapticFeedback.selectionClick();
        setState(() {
          _dx = nx;
          _armed = armed;
        });
      },
      onHorizontalDragEnd: (_) {
        if (_armed) widget.onReply();
        setState(() {
          _dx = 0;
          _armed = false;
        });
      },
      child: Stack(alignment: Alignment.centerRight, children: [
        if (_dx < 0)
          Positioned(
            right: 8,
            child: Opacity(
              opacity: (-_dx / 56).clamp(0.0, 1.0),
              child: CircleAvatar(radius: 16, backgroundColor: Colors.black26, child: Icon(Icons.reply, size: 18, color: Colors.white.withValues(alpha: 0.9))),
            ),
          ),
        AnimatedContainer(
          duration: Duration(milliseconds: _dx == 0 ? 180 : 0),
          transform: Matrix4.translationValues(_dx, 0, 0),
          child: widget.child,
        ),
      ]),
    );
  }
}

class _Blink extends StatefulWidget {
  const _Blink();
  @override
  State<_Blink> createState() => _BlinkState();
}

class _BlinkState extends State<_Blink> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 700))..repeat(reverse: true);
  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FadeTransition(
        opacity: _c,
        child: Container(width: 10, height: 10, decoration: const BoxDecoration(color: Colors.redAccent, shape: BoxShape.circle)),
      );
}

class _DayChip extends StatelessWidget {
  final DateTime d;
  const _DayChip(this.d);
  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final s = DateUtils.isSameDay(d, now)
        ? 'Сегодня'
        : DateUtils.isSameDay(d, now.subtract(const Duration(days: 1)))
            ? 'Вчера'
            : DateFormat(d.year == now.year ? 'd MMMM' : 'd MMMM y', 'ru').format(d);
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
            decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.22), borderRadius: BorderRadius.circular(12)),
            child: Text(text, style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w500)),
          ),
        ),
      );
}

class _Bubble extends StatelessWidget {
  final Event event;
  final Timeline timeline;
  final Room room;
  final bool showName, tail, showAvatar, avatarSpace;
  final void Function(String key) onReact;
  final void Function(String id) onReplyTap;
  const _Bubble({
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
      if (exp > 0) Text('🔥${fmtLeft(exp - DateTime.now().millisecondsSinceEpoch)} ', style: TextStyle(fontSize: 11.5, color: metaColor)),
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
    } else if (isImage || isSticker) {
      content = _Image(e, sticker: isSticker);
    } else if (e.messageType == MessageTypes.Audio) {
      content = VoiceMessage(event: e, color: mine ? const Color(0xFF4FAE4E) : accent);
    } else if (e.messageType == MessageTypes.File || e.messageType == MessageTypes.Video) {
      final size = (e.content.tryGetMap<String, Object?>('info')?['size'] as num?)?.toInt();
      content = InkWell(
        onTap: () => openAttachment(e, (s) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s)))),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          CircleAvatar(
            radius: 22,
            backgroundColor: mine ? const Color(0xFF4FAE4E) : accent,
            child: Icon(e.messageType == MessageTypes.Video ? Icons.play_arrow : Icons.insert_drive_file, color: Colors.white),
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
      content = Text(e.calcUnlocalizedBody(hideReply: true), style: TextStyle(fontSize: 16, height: 1.3, color: mine ? Bubbles.outText(context) : null));
    }

    final replyId = event.content.tryGetMap<String, Object?>('m.relates_to')?.tryGetMap<String, Object?>('m.in_reply_to')?.tryGet<String>('event_id');
    final maxW = min(paneWidth(context) * (avatarSpace ? 0.74 : 0.8), 520.0);
    final bareMedia = isSticker; // стикер без пузыря, как в Telegram
    final isText = !isImage && !isSticker && e.messageType != MessageTypes.Audio && e.messageType != MessageTypes.File;

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
    final maxW = sticker ? 170.0 : min(paneWidth(context) * 0.7, 400.0);
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
        borderRadius: BorderRadius.circular(sticker ? 0 : 13),
        child: SizedBox(
          width: maxW,
          child: AspectRatio(
            aspectRatio: sticker ? 1 : ratio.clamp(0.5, 2.5),
            child: FutureBuilder<Uint8List?>(
              future: _load(),
              builder: (_, s) => s.data == null
                  ? Container(color: sticker ? Colors.transparent : Colors.black12, child: s.connectionState == ConnectionState.done ? const Icon(Icons.broken_image_outlined) : null)
                  : Image.memory(s.data!, fit: sticker ? BoxFit.contain : BoxFit.cover, gaplessPlayback: true),
            ),
          ),
        ),
      ),
    );
  }
}

/// Ширина области чата: на планшете чат занимает только правую часть экрана.
class _PaneWidth extends InheritedWidget {
  final double width;
  const _PaneWidth({required this.width, required super.child});
  @override
  bool updateShouldNotify(_PaneWidth old) => old.width != width;
}

double paneWidth(BuildContext context) =>
    context.dependOnInheritedWidgetOfExactType<_PaneWidth>()?.width ?? MediaQuery.sizeOf(context).width;
