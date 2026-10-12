import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:matrix/matrix.dart';

import '../widgets/adaptive.dart';
import '../widgets/wallpaper.dart';
import '../main.dart';
import '../calls/voip.dart';
import '../chat/autodelete.dart';
import '../chat/drafts.dart';
import '../chat/global_search.dart';
import '../chat/saved.dart';
import 'people.dart';
import 'qr.dart';
import '../chat/formatting.dart';
import '../chat/polls.dart';
import '../system/perf.dart';
import '../widgets/avatar.dart';
import '../widgets/login_banner.dart';
import '../widgets/clock_banner.dart';
import '../widgets/update_banner.dart';
import 'chat.dart';
import 'home.dart' show ContactsPage, CallsPage;
import 'settings.dart';

String previewText(Room room) {
  final ev = room.lastEvent;
  if (room.membership == Membership.invite) return 'Приглашение в чат';
  if (ev == null) return '';
  if (isExpired(ev)) return '🔥 Сообщение исчезло';
  if (ev.type == EventTypes.Encrypted) return '🔒 Зашифрованное сообщение';
  if (ev.redacted) return 'Сообщение удалено';
  String body;
  if (ev.type == EventTypes.Message || ev.type == EventTypes.Sticker) {
    body = switch (ev.messageType) {
      MessageTypes.Image => '🖼 Фото',
      MessageTypes.Video => '🎬 Видео',
      'm.key.verification.request' => '🔐 Запрос подтверждения',
      MessageTypes.Audio => ev.content.containsKey('org.matrix.msc3245.voice') ? '🎤 Голосовое сообщение' : '🎵 ${ev.body}',
      MessageTypes.File => '📎 ${ev.body}',
      MessageTypes.Sticker => 'Стикер',
      _ => ev.type == EventTypes.Sticker ? 'Стикер' : stripMarkdown(ev.body),
    };
  } else if (isPollStart(ev)) {
    body = pollPreview(ev);
  } else if (ev.type == EventTypes.CallInvite) {
    body = '📞 Звонок';
  } else {
    body = memberText(ev) ?? '';
  }
  if (!room.isDirectChat && ev.type == EventTypes.Message) {
    final who = ev.senderId == client.userID ? 'Вы' : ev.senderFromMemoryOrFallback.calcDisplayname();
    return '$who: $body';
  }
  return body;
}

/// Короткое описание входа/выхода участника (по-русски).
String? memberText(Event ev) {
  if (ev.type != EventTypes.RoomMember) return null;
  final name = ev.content.tryGet<String>('displayname') ?? ev.stateKey?.localpart ?? '';
  final prev = ev.prevContent?.tryGet<String>('membership');
  return switch (ev.content.tryGet<String>('membership')) {
    'join' when prev == 'join' => null,
    'join' => '$name вступает в чат',
    'invite' => '$name приглашается в чат',
    'leave' => '$name покидает чат',
    'ban' => '$name заблокирован(а)',
    _ => null,
  };
}

String shortTime(DateTime t) {
  final now = DateTime.now();
  if (now.year == t.year && now.month == t.month && now.day == t.day) return DateFormat.Hm('ru').format(t);
  if (now.difference(t).inDays < 7) return DateFormat.E('ru').format(t);
  return DateFormat('dd.MM.yy').format(t);
}

const archiveTag = 'ru.lastochka.archive';
const foldersType = 'ru.lastochka.folders';
const builtinFolders = [('all', 'Все'), ('direct', 'Личные'), ('groups', 'Группы'), ('unread', 'Непрочитанные')];

bool isArchived(Room r) => r.tags.containsKey(archiveTag);

/// Свои папки — в данных аккаунта, поэтому одинаковые на всех ваших устройствах.
class UserFolder {
  final String id, name;
  final List<String> rooms;
  UserFolder(this.id, this.name, this.rooms);
  Map<String, Object?> toJson() => {'id': id, 'name': name, 'rooms': rooms};
}

List<UserFolder> userFolders() {
  final list = client.accountData[foldersType]?.content['folders'];
  if (list is! List) return [];
  return [
    for (final f in list)
      if (f is Map && f['id'] is String && f['name'] is String)
        UserFolder(f['id'] as String, f['name'] as String, (f['rooms'] is List ? (f['rooms'] as List).whereType<String>().toList() : <String>[])),
  ];
}

Future<void> saveFolders(List<UserFolder> f) async {
  final content = {'folders': f.map((x) => x.toJson()).toList()};
  await client.setAccountData(client.userID!, foldersType, content);
  // сразу видно, не дожидаясь синхронизации (и две быстрые правки не затирают друг друга)
  client.accountData[foldersType] = BasicEvent(type: foldersType, content: content);
}

class ChatsPage extends StatefulWidget {
  const ChatsPage({super.key});
  @override
  State<ChatsPage> createState() => _ChatsPageState();
}

class _ChatsPageState extends State<ChatsPage> {
  StreamSubscription? _sub;
  String _folder = 'all';
  Room? _selected; // открытый чат справа (планшет)
  String? _jump; // перейти к сообщению (из поиска)
  bool _wide = false;
  bool _searching = false;
  // на широком экране меню выезжает поверх всего окна (а не только списка чатов) и закрывается кликом в любом месте
  final _outer = GlobalKey<ScaffoldState>();
  final _inner = GlobalKey<ScaffoldState>();
  int _leftTab = 0; // компьютер: 0 — чаты, 1 — контакты, 2 — звонки (настройки — окном)
  Future<Profile>? _me;
  void _openMenu() => (_wide ? _outer : _inner).currentState?.openDrawer();
  final _q = TextEditingController();
  List<Profile> _people = [];
  Timer? _peopleTimer;
  String _peopleFor = '';

  // поиск сообщений во всех чатах
  final _gs = GlobalSearch();
  List<SearchHit> _msgHits = [];
  bool _msgSearching = false;
  Timer? _msgTimer;

  void _searchMessages() {
    _msgTimer?.cancel();
    _gs.cancel();
    final q = _q.text.trim();
    if (q.length < 3) {
      setState(() {
        _msgHits = [];
        _msgSearching = false;
      });
      return;
    }
    _msgTimer = Timer(const Duration(milliseconds: 700), () {
      if (!mounted || !_searching) return;
      setState(() => _msgSearching = true);
      _gs.run(q, (hits, done) {
        if (!mounted || _q.text.trim() != q) return;
        setState(() {
          _msgHits = hits;
          _msgSearching = !done;
        });
      });
    });
  }

  // поиск людей на сервере (каталог пользователей) — чтобы написать тому, с кем ещё нет чата
  void _searchPeople() {
    _searchMessages();
    final q = _q.text.trim();
    _peopleTimer?.cancel();
    if (q.length < 2) {
      if (_people.isNotEmpty) setState(() => _people = []);
      return;
    }
    _peopleTimer = Timer(const Duration(milliseconds: 400), () async {
      try {
        final r = await client.searchUserDirectory(q, limit: 10);
        if (!mounted || _q.text.trim() != q) return;
        final direct = client.rooms.where((x) => x.isDirectChat).map((x) => x.directChatMatrixID).toSet();
        setState(() {
          _peopleFor = q;
          _people = r.results.where((p) => p.userId != client.userID && !direct.contains(p.userId)).toList();
        });
      } catch (_) {}
    });
  }

  Future<void> _openPerson(Profile p) async {
    try {
      final id = await client.startDirectChat(p.userId, enableEncryption: true);
      final room = client.getRoomById(id) ?? await client.waitForRoomInSync(id).then((_) => client.getRoomById(id));
      if (room != null && mounted) {
        setState(() {
          _searching = false;
          _q.clear();
          _people = [];
        });
        _open(room);
      }
    } catch (_) {
      _toast('Не удалось начать чат');
    }
  }

  @override
  void initState() {
    super.initState();
    // перерисовываем список, только если в синхронизации было что-то про чаты, и не чаще 4 раз в секунду
    _sub = client.onSync.stream.listen((s) {
      if (s.rooms != null || s.accountData != null || s.presence != null) _redraw();
    });
    Drafts.instance.changed.addListener(_redraw);
    _me = client.fetchOwnProfile();
  }

  Timer? _redrawTimer;
  void _redraw() {
    if (_redrawTimer?.isActive == true) return;
    // на удалённом рабочем столе кадры дорогие — перерисовываем реже
    _redrawTimer = Timer(Duration(milliseconds: remoteSession ? 700 : 250), () {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    Drafts.instance.changed.removeListener(_redraw);
    _redrawTimer?.cancel();
    _msgTimer?.cancel();
    _gs.cancel();
    _sub?.cancel();
    super.dispose();
  }

  // Открытый справа чат — один и тот же экземпляр виджета, пока не выбран другой чат:
  // тогда обновление списка (новые сообщения, «печатает…», отметки) не перерисовывает всю переписку.
  Widget? _pane;
  String? _paneKey;
  Widget _chatPane(Room sel) {
    final k = '${sel.id}|$_jump';
    if (_pane == null || _paneKey != k) {
      _paneKey = k;
      _pane = ChatPage(key: ValueKey(k), room: sel, embedded: true, jumpTo: _jump);
    }
    return _pane!;
  }

  List<Room> get _rooms {
    final q = _q.text.trim().toLowerCase();
    final list = client.rooms.where((r) {
      if (r.membership == Membership.leave || r.membership == Membership.ban) return false;
      if (q.isNotEmpty && !r.getLocalizedDisplayname().toLowerCase().contains(q)) return false;
      // в поиске видны и архивные чаты
      if (_folder == 'archive') return isArchived(r);
      if (isArchived(r) && q.isEmpty) return false;
      if (_folder.startsWith('f:')) {
        final f = userFolders().where((x) => 'f:${x.id}' == _folder).firstOrNull;
        return f != null && f.rooms.contains(r.id);
      }
      return switch (_folder) {
        'direct' => r.isDirectChat,
        'groups' => !r.isDirectChat,
        'unread' => r.isUnreadOrInvited,
        _ => true,
      };
    }).toList();
    // «Избранное» — первым, остальные — в прежнем порядке
    return [...list.where(isSaved), ...list.where((r) => !isSaved(r))];
  }

  // ---------- папки ----------
  Future<void> _editFolder([UserFolder? f]) async {
    final name = TextEditingController(text: f?.name ?? '');
    final sel = <String>{...?f?.rooms};
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => StatefulBuilder(
        builder: (d, set) => AlertDialog(
          title: Text(f == null ? 'Новая папка' : 'Папка'),
          content: SizedBox(
            width: 420,
            height: 460,
            child: Column(children: [
              TextField(enableIMEPersonalizedLearning: false, controller: name, autofocus: f == null, maxLength: 24, decoration: const InputDecoration(hintText: 'Название, например «Работа»')),
              Expanded(
                child: ListView(children: [
                  for (final r in client.rooms.where((r) => r.membership == Membership.join))
                    CheckboxListTile(
                      value: sel.contains(r.id),
                      onChanged: (v) => set(() => v == true ? sel.add(r.id) : sel.remove(r.id)),
                      secondary: Avatar(mxc: r.avatar, name: r.getLocalizedDisplayname(), size: 36),
                      title: Text(r.getLocalizedDisplayname(), maxLines: 1, overflow: TextOverflow.ellipsis),
                    ),
                ]),
              ),
            ]),
          ),
          actions: [
            if (f != null) TextButton(onPressed: () => Navigator.pop(d, null), child: const Text('Отмена')),
            if (f != null)
              TextButton(
                onPressed: () async {
                  Navigator.pop(d, false);
                  await saveFolders(userFolders().where((x) => x.id != f.id).toList());
                  if (_folder == 'f:${f.id}') setState(() => _folder = 'all');
                },
                child: const Text('Удалить папку', style: TextStyle(color: Colors.redAccent)),
              )
            else
              TextButton(onPressed: () => Navigator.pop(d, null), child: const Text('Отмена')),
            FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('Сохранить')),
          ],
        ),
      ),
    );
    if (ok != true || name.text.trim().isEmpty) return;
    final list = userFolders();
    final id = f?.id ?? DateTime.now().millisecondsSinceEpoch.toRadixString(36);
    final nf = UserFolder(id, name.text.trim(), sel.toList());
    final i = list.indexWhere((x) => x.id == id);
    i >= 0 ? list[i] = nf : list.add(nf);
    try {
      await saveFolders(list);
      setState(() => _folder = 'f:$id');
    } catch (_) {
      _toast('Не удалось сохранить папку');
    }
  }

  Future<void> _addToFolder(Room room) async {
    final list = userFolders();
    final pick = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (c) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          for (final f in list)
            CheckboxListTile(
              value: f.rooms.contains(room.id),
              title: Text(f.name),
              onChanged: (_) => Navigator.pop(c, f.id),
            ),
          ListTile(leading: const Icon(Icons.create_new_folder_outlined), title: const Text('Новая папка'), onTap: () => Navigator.pop(c, '+')),
        ]),
      ),
    );
    if (pick == null) return;
    if (pick == '+') return _editFolder(UserFolder('${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}', '', [room.id]));
    final f = list.firstWhere((x) => x.id == pick);
    f.rooms.contains(room.id) ? f.rooms.remove(room.id) : f.rooms.add(room.id);
    await saveFolders(list);
  }

  /// Новый чат, как в Telegram: сразу список людей, сверху — «Новая группа», «Найти группу», QR.
  Future<void> _newChat() async {
    final r = await pickPeople(
      context,
      title: 'Новый чат',
      multi: false,
      actions: [
        const PickerAction(Icons.group_add_outlined, 'Новая группа', 'group'),
        const PickerAction(Icons.travel_explore, 'Найти группу', 'join'),
        if (canScanQr) const PickerAction(Icons.qr_code_scanner, 'Сканировать QR-код', 'qr'),
      ],
    );
    if (r == null || !mounted) return;
    if (r.action == 'qr') {
      final v = await scanQr(context);
      if (v != null && mounted) await openMatrixLink(context, v);
      return;
    }
    if (r.action != null) return _newChatOf(r.action!);
    if (r.ids.isNotEmpty) await _create(() => client.startDirectChat(r.ids.first, enableEncryption: true), 'dm');
  }

  Future<void> _newChatOf(String action) async {
    if (action == 'dm') return _newChat();
    if (action == 'group') {
      final r = await pickPeople(context, title: 'Новая группа', doneLabel: 'Далее', allowEmpty: true);
      if (r == null || !mounted) return;
      final name = await _ask('Название группы', 'Например: Отдел продаж');
      if (name == null || name.isEmpty) return;
      await _create(() => client.createGroupChat(groupName: name, invite: r.ids, enableEncryption: true, preset: CreateRoomPreset.privateChat), 'group');
      return;
    }
    final input = await _ask('Найти группу', 'Адрес группы, например #общий:сервер');
    if (input == null || input.isEmpty) return;
    await _create(() => client.joinRoom(input.startsWith('#') || input.startsWith('!') ? input : '#$input'), 'join');
  }

  Future<void> _create(Future<String> Function() make, String action) async {
    try {
      final roomId = await make();
      final room = client.getRoomById(roomId) ?? await client.waitForRoomInSync(roomId).then((_) => client.getRoomById(roomId));
      if (room != null && mounted) _open(room);
    } on MatrixException catch (e) {
      _toast(switch (e.errcode) {
        'M_NOT_FOUND' => action == 'join' ? 'Группа не найдена' : 'Пользователь не найден',
        'M_FORBIDDEN' => 'Нет доступа',
        _ => e.errorMessage,
      });
    } catch (_) {
      _toast('Не получилось. Проверьте адрес и подключение');
    }
  }

  Future<String?> _ask(String title, String hint) {
    final c = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text(title),
        content: TextField(enableIMEPersonalizedLearning: false, controller: c, autofocus: true, autocorrect: false, decoration: InputDecoration(hintText: hint), onSubmitted: (v) => Navigator.pop(d, v.trim())),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d), child: const Text('Отмена')),
          FilledButton(onPressed: () => Navigator.pop(d, c.text.trim()), child: const Text('Готово')),
        ],
      ),
    );
  }

  void _toast(String s) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s)));

  Future<void> _open(Room room, {String? jumpTo}) async {
    if (room.membership == Membership.invite) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (d) => AlertDialog(
          title: Text(room.getLocalizedDisplayname()),
          content: const Text('Вас пригласили в этот чат.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Отклонить')),
            FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('Вступить')),
          ],
        ),
      );
      if (ok == null) return;
      if (!ok) return room.leave();
      await room.join();
    }
    if (!mounted) return;
    if (_wide) {
      _jump = jumpTo;
      return setState(() => _selected = room);
    }
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => ChatPage(room: room, jumpTo: jumpTo)));
  }

  Future<void> _menu(Room room) async {
    final fav = room.isFavourite;
    final muted = room.pushRuleState != PushRuleState.notify;
    final a = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (c) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          if (canCall(room)) ...[
            ListTile(leading: const Icon(Icons.call_outlined), title: const Text('Аудиозвонок'), onTap: () => Navigator.pop(c, 'call')),
            ListTile(leading: const Icon(Icons.videocam_outlined), title: const Text('Видеозвонок'), onTap: () => Navigator.pop(c, 'video')),
          ],
          ListTile(leading: Icon(fav ? Icons.push_pin : Icons.push_pin_outlined), title: Text(fav ? 'Открепить' : 'Закрепить'), onTap: () => Navigator.pop(c, 'fav')),
          ListTile(leading: Icon(muted ? Icons.notifications_outlined : Icons.notifications_off_outlined), title: Text(muted ? 'Включить уведомления' : 'Без звука'), onTap: () => Navigator.pop(c, 'mute')),
          ListTile(leading: const Icon(Icons.mark_chat_read_outlined), title: const Text('Отметить прочитанным'), onTap: () => Navigator.pop(c, 'read')),
          ListTile(leading: const Icon(Icons.folder_outlined), title: const Text('Папки…'), onTap: () => Navigator.pop(c, 'folder')),
          ListTile(
            leading: Icon(isArchived(room) ? Icons.unarchive_outlined : Icons.archive_outlined),
            title: Text(isArchived(room) ? 'Вернуть из архива' : 'В архив'),
            onTap: () => Navigator.pop(c, 'archive'),
          ),
          ListTile(leading: const Icon(Icons.logout, color: Colors.redAccent), title: const Text('Покинуть чат', style: TextStyle(color: Colors.redAccent)), onTap: () => Navigator.pop(c, 'leave')),
        ]),
      ),
    );
    try {
      switch (a) {
        case 'call' || 'video':
          if (mounted) await startCall(context, room, video: a == 'video');
        case 'fav':
          await room.setFavourite(!fav);
        case 'mute':
          await room.setPushRuleState(muted ? PushRuleState.notify : PushRuleState.mentionsOnly);
        case 'folder':
          await _addToFolder(room);
        case 'archive':
          final was = isArchived(room);
          was ? await room.removeTag(archiveTag) : await room.addTag(archiveTag);
          if (mounted) _toast(was ? 'Чат возвращён из архива' : 'Чат в архиве');
          if (was && _folder == 'archive' && client.rooms.where(isArchived).length <= 1) _folder = 'all';
        case 'read':
          final id = room.lastEvent?.eventId;
          if (id != null) await room.setReadMarker(id, mRead: id);
        case 'leave':
          await room.leave();
          if (_selected?.id == room.id) _selected = null;
      }
    } catch (_) {
      _toast('Не получилось');
    }
    if (mounted) setState(() {});
  }

  // Планшет или телефон в альбомной ориентации: список слева, чат справа (как в Telegram).
  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      _wide = c.maxWidth >= 720;
      if (!_wide) return _list(context);
      final sel = _selected == null ? null : client.getRoomById(_selected!.id);
      final listW = (c.maxWidth * 0.36).clamp(320.0, 420.0);
      // на широком экране — два закруглённых «листа» на подложке, как в современных мессенджерах
      final dark = Theme.of(context).brightness == Brightness.dark;
      return Scaffold(
        key: _outer,
        drawer: _drawer(context),
        backgroundColor: dark ? const Color(0xFF151515) : const Color(0xFFE9ECF0),
        body: Row(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 4, 8),
          child: ClipRRect(borderRadius: BorderRadius.circular(18), child: SizedBox(width: listW - 12, child: _leftPane(context))),
        ),
        Expanded(
          child: Padding(
          padding: const EdgeInsets.fromLTRB(4, 8, 8, 8),
          child: ClipRRect(
          borderRadius: BorderRadius.circular(18),
          // чат не выбран — просто обои с узором, без надписи
          child: sel == null || sel.membership != Membership.join ? const ChatWallpaper() : _chatPane(sel),
          ),
          ),
        ),
      ]),
      );
    });
  }

  /// Компьютер и Mac: слева — чаты, контакты или звонки, внизу — переключатель, как в Telegram Desktop.
  Widget _leftPane(BuildContext context) {
    return Column(children: [
      Expanded(
        child: IndexedStack(index: _leftTab, children: [
          _list(context),
          _leftTab == 1 ? ContactsPage(onOpen: (r) => _open(r)) : const SizedBox.shrink(),
          _leftTab == 2 ? CallsPage(onOpen: (r) => _open(r)) : const SizedBox.shrink(),
        ]),
      ),
      NavigationBar(
        height: 62,
        selectedIndex: _leftTab,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        onDestinationSelected: (i) {
          if (i == 3) {
            pushAdaptive<void>(context, (_) => const SettingsPage(), maxWidth: 620);
            return;
          }
          setState(() => _leftTab = i);
        },
        destinations: const [
          NavigationDestination(icon: Icon(Icons.chat_bubble_outline_rounded), selectedIcon: Icon(Icons.chat_bubble_rounded), label: 'Чаты'),
          NavigationDestination(icon: Icon(Icons.person_outline_rounded), selectedIcon: Icon(Icons.person_rounded), label: 'Контакты'),
          NavigationDestination(icon: Icon(Icons.call_outlined), selectedIcon: Icon(Icons.call_rounded), label: 'Звонки'),
          NavigationDestination(icon: Icon(Icons.settings_outlined), selectedIcon: Icon(Icons.settings_rounded), label: 'Настройки'),
        ],
      ),
    ]);
  }

  Widget _list(BuildContext context) {
    final rooms = _rooms;
    final hint = Theme.of(context).hintColor;
    final accent = Theme.of(context).colorScheme.primary;
    return Scaffold(
      key: _inner,
      appBar: AppBar(
        // вместо «трёх полосок» — своя аватарка и имя (нажатие открывает меню), над именем — «Ласточка»
        automaticallyImplyLeading: false,
        titleSpacing: 12,
        title: _searching
            ? TextField(enableIMEPersonalizedLearning: false, 
                controller: _q,
                autofocus: true,
                onChanged: (_) {
                  setState(() {});
                  _searchPeople();
                },
                decoration: InputDecoration(
                  hintText: 'Поиск',
                  isDense: true,
                  suffixIcon: _q.text.isEmpty ? null : IconButton(icon: const Icon(Icons.close), onPressed: () => setState(_q.clear)),
                ),
              )
            : _Header(me: _me, onTap: _openMenu),
        actions: [
          IconButton(
            icon: Icon(_searching ? Icons.arrow_forward : Icons.search),
            onPressed: () => setState(() {
              _searching = !_searching;
              if (!_searching) {
                _q.clear();
                _people = [];
                _msgHits = [];
                _msgSearching = false;
                _gs.cancel();
                _msgTimer?.cancel();
              }
            }),
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(46),
          // папки: по центру, если помещаются; иначе листаются с одинаковыми отступами по краям
          child: SizedBox(
            height: 46,
            child: LayoutBuilder(builder: (_, c) {
              final folders = [
                ...builtinFolders,
                for (final f in userFolders()) ('f:${f.id}', f.name),
                if (client.rooms.any(isArchived)) ('archive', '🗄 Архив'),
              ];
              final row = Row(mainAxisSize: MainAxisSize.min, children: [
                for (final (id, name) in folders)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 7),
                    child: GestureDetector(
                      onLongPress: id.startsWith('f:') ? () => _editFolder(userFolders().firstWhere((f) => 'f:${f.id}' == id)) : null,
                      child: ChoiceChip(
                        label: Text(name),
                        selected: _folder == id,
                        showCheckmark: false,
                        visualDensity: VisualDensity.compact,
                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        labelPadding: const EdgeInsets.symmetric(horizontal: 2),
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        labelStyle: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w500),
                        side: _folder == id ? BorderSide.none : BorderSide(color: Theme.of(context).dividerColor.withValues(alpha: 0.4)),
                        shape: const StadiumBorder(),
                        onSelected: (_) => setState(() => _folder = id),
                      ),
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 7),
                  child: Tooltip(
                    message: 'Новая папка (удерживайте папку, чтобы изменить)',
                    child: ActionChip(
                      label: const Icon(Icons.add, size: 18),
                      visualDensity: VisualDensity.compact,
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      labelPadding: EdgeInsets.zero,
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      side: BorderSide(color: Theme.of(context).dividerColor.withValues(alpha: 0.4)),
                      shape: const StadiumBorder(),
                      onPressed: () => _editFolder(),
                    ),
                  ),
                ),
              ]);
              // немного папок — всё в одну строку (чуть уменьшается, если тесно); много — листаются
              if (folders.length <= 6) {
                return Padding(padding: const EdgeInsets.symmetric(horizontal: 8), child: Center(child: FittedBox(fit: BoxFit.scaleDown, child: row)));
              }
              return SingleChildScrollView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 8), child: row);
            }),
          ),
        ),
      ),
      drawer: _wide ? null : _drawer(context),
      floatingActionButton: FloatingActionButton(onPressed: _newChat, tooltip: 'Новый чат', child: const Icon(Icons.edit_outlined)),
      body: Column(children: [
        const UpdateBanner(),
        const ClockBanner(),
        const NewLoginBanner(),
        Expanded(child: client.prevBatch == null && client.rooms.isEmpty
          ? const Center(child: CircularProgressIndicator())
          : rooms.isEmpty && _people.isEmpty && _msgHits.isEmpty && !_msgSearching
              ? Center(child: Text(_q.text.isEmpty ? 'Здесь пока нет чатов' : 'Ничего не найдено', style: TextStyle(color: hint)))
              : ListView.builder(
                  itemCount: rooms.length + (_people.isEmpty || _peopleFor != _q.text.trim() ? 0 : _people.length + 1) + (_searching && _q.text.trim().length >= 3 ? _msgHits.length + 1 : 0),
                  itemBuilder: (_, i) {
                    final peopleN = _people.isEmpty || _peopleFor != _q.text.trim() ? 0 : _people.length + 1;
                    if (i >= rooms.length + peopleN) {
                      final k = i - rooms.length - peopleN;
                      if (k == 0) {
                        return Padding(
                          padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
                          child: Row(children: [
                            Text('Сообщения', style: TextStyle(color: accent, fontWeight: FontWeight.w600)),
                            if (_msgSearching) const Padding(padding: EdgeInsets.only(left: 10), child: SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))),
                            if (!_msgSearching && _msgHits.isEmpty) Padding(padding: const EdgeInsets.only(left: 10), child: Text('не найдено', style: TextStyle(color: hint))),
                          ]),
                        );
                      }
                      final h = _msgHits[k - 1];
                      final rn = h.room.getLocalizedDisplayname();
                      return ListTile(
                        leading: isSaved(h.room) ? const SavedAvatar(size: 44) : Avatar(mxc: h.room.avatar, name: rn, size: 44),
                        title: Row(children: [
                          Expanded(child: Text(isSaved(h.room) ? savedName : rn, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600))),
                          Text(shortTime(h.event.originServerTs), style: TextStyle(fontSize: 12.5, color: hint)),
                        ]),
                        subtitle: Text('${h.event.senderId == client.userID ? 'Вы' : h.event.senderFromMemoryOrFallback.calcDisplayname()}: ${h.text.replaceAll('\n', ' ')}', maxLines: 2, overflow: TextOverflow.ellipsis),
                        onTap: () => _open(h.room, jumpTo: h.event.eventId),
                      );
                    }
                    if (i == rooms.length) {
                      return Padding(
                        padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
                        child: Text('Люди на сервере', style: TextStyle(color: accent, fontWeight: FontWeight.w600)),
                      );
                    }
                    if (i > rooms.length) {
                      final p = _people[i - rooms.length - 1];
                      final pn = p.displayName ?? p.userId.localpart ?? p.userId;
                      return ListTile(
                        leading: Avatar(mxc: p.avatarUrl, name: pn, size: 48),
                        title: Text(pn, style: const TextStyle(fontWeight: FontWeight.w600)),
                        subtitle: const Text('Написать сообщение'),
                        onTap: () => _openPerson(p),
                      );
                    }
                    final r = rooms[i];
                    final saved = isSaved(r);
                    final name = saved ? savedName : r.getLocalizedDisplayname();
                    final unread = r.notificationCount;
                    final muted = r.pushRuleState != PushRuleState.notify;
                    final ts = r.lastEvent?.originServerTs;
                    final last = r.lastEvent;
                    final mineLast = last != null && last.senderId == client.userID && last.type == EventTypes.Message;
                    final readLast = mineLast && r.receiptState.global.otherUsers.values.any((x) => x.ts >= last.originServerTs.millisecondsSinceEpoch);
                    final typing = r.typingUsers.where((u) => u.id != client.userID).toList();
                    // выбранный чат на компьютере — залит цветом, как в Telegram Desktop
                    final sel = _wide && _selected?.id == r.id;
                    final tHint = sel ? Colors.white.withValues(alpha: 0.78) : hint;
                    final tAccent = sel ? Colors.white : accent;
                    return Padding(
                      padding: EdgeInsets.symmetric(horizontal: _wide ? 6 : 0, vertical: _wide ? 1 : 0),
                      child: GestureDetector(
                      onSecondaryTap: () => _menu(r), // правая кнопка мыши — меню чата
                      child: ListTile(
                      selected: sel,
                      selectedTileColor: Theme.of(context).colorScheme.primary,
                      selectedColor: Colors.white,
                      shape: _wide ? RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)) : null,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      minVerticalPadding: 6,
                      leading: saved ? const SavedAvatar() : Avatar(mxc: r.avatar, name: name, size: 54),
                      title: Row(children: [
                        if (r.encrypted && r.isDirectChat) Padding(padding: const EdgeInsets.only(right: 3), child: Icon(Icons.lock, size: 14, color: Colors.green.shade600)),
                        Expanded(child: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16.5))),
                        if (muted) Padding(padding: const EdgeInsets.only(left: 3), child: Icon(Icons.volume_off, size: 15, color: tHint)),
                        if (mineLast) Padding(padding: const EdgeInsets.only(left: 6), child: Icon(readLast ? Icons.done_all : Icons.done, size: 16, color: sel ? Colors.white : Colors.green.shade600)),
                        if (ts != null) Padding(padding: const EdgeInsets.only(left: 4), child: Text(shortTime(ts), style: TextStyle(fontSize: 12.5, color: unread > 0 && !muted ? tAccent : tHint))),
                      ]),
                      subtitle: Padding(
                        padding: const EdgeInsets.only(top: 3),
                        child: Row(children: [
                          Expanded(
                            child: typing.isEmpty && Drafts.instance.of(r.id) != null && (!_wide || _selected?.id != r.id)
                                ? Text.rich(
                                    TextSpan(children: [
                                      const TextSpan(text: 'Черновик: ', style: TextStyle(color: Colors.redAccent)),
                                      TextSpan(text: stripMarkdown(Drafts.instance.of(r.id)!).replaceAll('\n', ' ')),
                                    ]),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(color: tHint, fontSize: 15),
                                  )
                                : typing.isNotEmpty
                                ? Text(r.isDirectChat ? 'печатает…' : '${typing.first.calcDisplayname()} печатает…', maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: tAccent))
                                : Text(previewText(r), maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: tHint, fontSize: 15)),
                          ),
                          if (r.isFavourite && unread == 0) Icon(Icons.push_pin, size: 16, color: tHint),
                          if (unread > 0 || r.membership == Membership.invite)
                            Container(
                              margin: const EdgeInsets.only(left: 6),
                              constraints: const BoxConstraints(minWidth: 22),
                              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                              decoration: BoxDecoration(color: sel ? Colors.white : muted ? tHint.withValues(alpha: 0.6) : tAccent, borderRadius: BorderRadius.circular(12)),
                              child: Text(unread > 0 ? '$unread' : '•', textAlign: TextAlign.center, style: TextStyle(color: sel ? Theme.of(context).colorScheme.primary : Colors.white, fontSize: 12.5, fontWeight: FontWeight.w600)),
                            ),
                        ]),
                      ),
                      onTap: () => _open(r),
                      onLongPress: () => _menu(r),
                    ),
                    ),
                    );
                  },
                ),
        ),
      ]),
    );
  }

  Widget _drawer(BuildContext context) {
    final me = client.userID ?? '';
    return Drawer(
      child: ListView(padding: EdgeInsets.zero, children: [
        FutureBuilder<Profile>(
          future: client.fetchOwnProfile(),
          builder: (_, s) {
            final name = s.data?.displayName ?? me.localpart ?? '';
            return DrawerHeader(
              margin: const EdgeInsets.fromLTRB(10, 10, 10, 6),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(18),
                gradient: Theme.of(context).brightness == Brightness.dark
                    ? const LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [Color(0xFF3A3550), Color(0xFF2B2B2B)])
                    : LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [Theme.of(context).colorScheme.primary, const Color(0xFF2A6FE0)]),
              ),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.end, children: [
                Avatar(mxc: s.data?.avatarUrl, name: name, size: 64),
                const SizedBox(height: 12),
                Text(name, style: const TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w600)),
                Text(me, style: TextStyle(color: Colors.white.withValues(alpha: 0.75), fontSize: 13.5)),
              ]),
            );
          },
        ),
        ListTile(leading: const Icon(Icons.person_add_alt_outlined), title: const Text('Новый личный чат'), onTap: () {
          Navigator.pop(context);
          _newChatOf('dm');
        }),
        ListTile(leading: const Icon(Icons.group_add_outlined), title: const Text('Создать группу'), onTap: () {
          Navigator.pop(context);
          _newChatOf('group');
        }),
        if (canScanQr)
          ListTile(leading: const Icon(Icons.qr_code_scanner), title: const Text('Сканировать QR-код'), onTap: () async {
            Navigator.pop(context);
            final v = await scanQr(context);
            if (v != null && mounted) await openMatrixLink(context, v);
          }),
        ListTile(leading: const Icon(Icons.travel_explore), title: const Text('Найти группу'), onTap: () {
          Navigator.pop(context);
          _newChatOf('join');
        }),
        const Divider(),
        ListTile(leading: const Icon(Icons.settings_outlined), title: const Text('Настройки'), onTap: () {
          Navigator.pop(context);
          pushAdaptive<void>(context, (_) => const SettingsPage(), maxWidth: 620);
        }),
      ]),
    );
  }
}

/// Шапка списка чатов: аватарка, «Ласточка» фирменной надписью и отображаемое имя.
class _Header extends StatelessWidget {
  final Future<Profile>? me;
  final VoidCallback onTap;
  const _Header({required this.me, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    final dark = Theme.of(context).brightness == Brightness.dark;
    return FutureBuilder<Profile>(
      future: me,
      builder: (context, s) {
        final id = client.userID ?? '';
        final name = s.data?.displayName ?? id.localpart ?? '';
        return Tooltip(
          message: 'Меню',
          child: InkWell(
            borderRadius: BorderRadius.circular(24),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Avatar(mxc: s.data?.avatarUrl, name: name, size: 38),
                const SizedBox(width: 10),
                Flexible(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                    // фирменная надпись: градиент и чуть разреженные буквы
                    ShaderMask(
                      blendMode: BlendMode.srcIn,
                      shaderCallback: (r) => LinearGradient(
                        colors: dark ? [const Color(0xFF9DB8FF), accent] : [const Color(0xFF2A6FE0), const Color(0xFF6B4FD8)],
                      ).createShader(r),
                      child: const Text('Ласточка', style: TextStyle(fontSize: 19, fontWeight: FontWeight.w700, letterSpacing: 0.3, height: 1.1)),
                    ),
                    Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: Theme.of(context).hintColor, height: 1.2)),
                  ]),
                ),
              ]),
            ),
          ),
        );
      },
    );
  }
}
