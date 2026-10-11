import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:pasteboard/pasteboard.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:matrix/matrix.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as p;

import 'package:photo_manager/photo_manager.dart' show AssetEntity, AssetType, ThumbnailSize;

import '../calls/voip.dart';
import '../chat/album.dart';
import '../chat/autodelete.dart';
import '../chat/gallery.dart';
import '../chat/drafts.dart';
import '../chat/formatting.dart';
import '../chat/forward.dart';
import '../chat/polls.dart';
import '../chat/video.dart';
import '../system/clipboard.dart';
import '../system/media_clean.dart';
import '../chat/stickers.dart';
import '../chat/voice.dart';
import '../main.dart';
import '../system/notify.dart';
import '../system/lru.dart';
import '../system/privacy.dart';
import '../system/trust.dart';
import 'verify.dart';
import '../theme.dart';
import '../widgets/avatar.dart';
import '../widgets/bubble_shape.dart';
import 'chats.dart';
import 'room_info.dart';

part 'chat_actions.dart';
part 'chat_bubble.dart';
part 'chat_compose.dart';
part 'chat_media.dart';
part 'chat_messages.dart';
part 'chat_search.dart';
part 'chat_widgets.dart';

final bool isDesktop = Platform.isWindows || Platform.isMacOS || Platform.isLinux;
const quickReactions = ['👍', '❤️', '😂', '😮', '😢', '🙏', '🔥', '👏'];

class ChatPage extends StatefulWidget {
  final Room room;
  final bool embedded; // показан справа от списка чатов (планшет, компьютер)
  final String? jumpTo; // сразу перейти к этому сообщению (из поиска)
  const ChatPage({super.key, required this.room, this.embedded = false, this.jumpTo});
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
  Map<String, List<Event>> _albums = const {}; // альбом: id первого показанного сообщения → все снимки
  // упоминания в сообщении: имя → @id
  final Map<String, String> _mentions = {};
  List<User> _mentionHits = [];
  // выбор нескольких сообщений
  Set<String>? _sel;

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
    // раз в секунду обновляются только таймеры 🔥, а весь чат — лишь когда сообщение исчезло
    _ttlTick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted || !_events.any((e) => expiryOf(e) > 0)) return;
      ttlTick.value++;
      if (_events.any(isExpired)) setState(() {});
    });
    _scroll.addListener(() {
      _updateFloatDate();
      if (_scroll.position.pixels > _scroll.position.maxScrollExtent - 600) _more();
      final down = _scroll.position.pixels > 400;
      if (down != _showDown) setState(() => _showDown = down);
    });
    final draft = Drafts.instance.of(room.id);
    if (draft != null) _text.text = draft;
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
    final j = widget.jumpTo;
    if (j != null) WidgetsBinding.instance.addPostFrameCallback((_) => _jumpTo(j));
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
    if (_editing == null) Drafts.instance.set(room.id, _text.text);
    _updateMentionHits();
    setState(() {});
    if (_text.text.isNotEmpty && DateTime.now().difference(_typingSent).inSeconds > 4) {
      _typingSent = DateTime.now();
      room.setTyping(true, timeout: 6000).catchError((_) {});
    }
  }

  // На компьютере Enter отправляет, Shift+Enter — новая строка
  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (!isDesktop || e is! KeyDownEvent) return KeyEventResult.ignored;
    final mod = HardwareKeyboard.instance.isControlPressed || HardwareKeyboard.instance.isMetaPressed;
    // Ctrl+V: картинка или файлы из буфера обмена (текст вставляется как обычно)
    if (mod && e.logicalKey == LogicalKeyboardKey.keyV) {
      unawaited(_pasteFromClipboard());
      return KeyEventResult.ignored;
    }
    // ↑ в пустом поле — изменить своё последнее сообщение, как в Telegram
    if (e.logicalKey == LogicalKeyboardKey.arrowUp && _text.text.isEmpty && _editing == null) {
      final tl = _tl;
      final last = tl == null
          ? null
          : _events.where((x) => x.senderId == client.userID && !x.redacted && x.type == EventTypes.Message && x.getDisplayEvent(tl).messageType == MessageTypes.Text).firstOrNull;
      if (last != null && tl != null) {
        setState(() {
          _replyTo = null;
          _editing = last;
          _text.text = last.getDisplayEvent(tl).body;
        });
        return KeyEventResult.handled;
      }
    }
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

  /// setState для частей экрана (они в отдельных файлах).
  void _set(VoidCallback f) => setState(f);

  void _toast(String s) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s), duration: const Duration(seconds: 2)));

  // ---------- файлы на компьютере: перетаскивание и вставка ----------
  bool _dragging = false;

  // Видимые события: сообщения, стикеры, вход/выход участников, звонки.
  bool _visible(Event e) {
    if (isExpired(e)) return false; // исчезнувшее сообщение
    if (ttlChangeText(e) != null) return true;
    if (e.relationshipType == RelationshipTypes.edit) return false;
    if (e.type == EventTypes.Message || e.type == EventTypes.Sticker || e.type == EventTypes.Encrypted) return true;
    if (isPollStart(e)) return true;
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
    final (events, albums) = groupAlbums(tl?.events.where(_visible).toList() ?? const <Event>[]);
    _events = events;
    _albums = albums;
    final typing = room.typingUsers.any((u) => u.id != client.userID);
    final accent = Theme.of(context).colorScheme.primary;
    return PopScope(
      canPop: _sel == null,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _sel != null) setState(() => _sel = null);
      },
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.keyF, control: true): () => setState(() => _searching = true),
          const SingleActivator(LogicalKeyboardKey.keyF, meta: true): () => setState(() => _searching = true),
          const SingleActivator(LogicalKeyboardKey.escape): () {
            if (_sel != null) return setState(() => _sel = null);
            if (_searching) return _closeSearch();
            if (_replyTo != null || _editing != null) _cancelBar();
          },
        },
        child: Scaffold(
      appBar: _sel != null ? _selBar(context) : AppBar(
        automaticallyImplyLeading: !widget.embedded,
        titleSpacing: widget.embedded ? 16 : 0,
        title: _searching
            ? TextField(enableIMEPersonalizedLearning: false, 
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
      body: DropTarget(
        enable: isDesktop,
        onDragEntered: (_) => setState(() => _dragging = true),
        onDragExited: (_) => setState(() => _dragging = false),
        onDragDone: (d) {
          setState(() => _dragging = false);
          _sendPaths(d.files.map((f) => f.path).toList());
        },
        child: Stack(children: [
          LayoutBuilder(
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
              // сжатие видео перед отправкой
              ValueListenableBuilder<double?>(
                valueListenable: compressProgress,
                builder: (_, v, __) => v == null
                    ? const SizedBox.shrink()
                    : Material(
                        color: Theme.of(context).scaffoldBackgroundColor,
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(14, 8, 14, 6),
                          child: Row(children: [
                            Icon(Icons.movie_filter_outlined, size: 18, color: accent),
                            const SizedBox(width: 8),
                            Text('Сжимаем видео… ${(v * 100).round()}%', style: const TextStyle(fontSize: 13.5)),
                            const SizedBox(width: 10),
                            Expanded(child: LinearProgressIndicator(value: v > 0 ? v : null, borderRadius: BorderRadius.circular(3))),
                          ]),
                        ),
                      ),
              ),
              _composer(context),
            ]),
          ),
        ),
      ),
          if (_dragging)
            Positioned.fill(
              child: IgnorePointer(
                child: Container(
                  margin: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.12),
                    border: Border.all(color: Theme.of(context).colorScheme.primary, width: 2),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  alignment: Alignment.center,
                  child: Text('Отпустите, чтобы отправить', style: TextStyle(fontSize: 18, color: Theme.of(context).colorScheme.primary, fontWeight: FontWeight.w600)),
                ),
              ),
            ),
        ]),
      ),
    ),
    ),
    );
  }

}
