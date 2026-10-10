import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:matrix/matrix.dart';

import '../main.dart';
import '../calls/voip.dart';
import '../chat/autodelete.dart';
import '../chat/drafts.dart';
import '../chat/global_search.dart';
import '../chat/saved.dart';
import 'qr.dart';
import '../chat/formatting.dart';
import '../chat/polls.dart';
import '../theme.dart';
import '../widgets/avatar.dart';
import '../widgets/login_banner.dart';
import '../widgets/update_banner.dart';
import 'chat.dart';
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
  }

  Timer? _redrawTimer;
  void _redraw() {
    if (_redrawTimer?.isActive == true) return;
    _redrawTimer = Timer(const Duration(milliseconds: 250), () {
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

  Future<void> _newChat() async {
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (c) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(leading: const Icon(Icons.person_outline), title: const Text('Новый личный чат'), onTap: () => Navigator.pop(c, 'dm')),
          ListTile(leading: const Icon(Icons.group_outlined), title: const Text('Новая группа'), onTap: () => Navigator.pop(c, 'group')),
          ListTile(leading: const Icon(Icons.travel_explore), title: const Text('Найти группу'), onTap: () => Navigator.pop(c, 'join')),
        ]),
      ),
    );
    if (action == null || !mounted) return;
    await _newChatOf(action);
  }

  Future<void> _newChatOf(String action) async {
    final hints = {
      'dm': ('Новый личный чат', 'Имя пользователя, например @ivan:сервер'),
      'group': ('Новая группа', 'Название группы'),
      'join': ('Найти группу', 'Адрес группы, например #общий:сервер'),
    }[action]!;
    final input = await _ask(hints.$1, hints.$2);
    if (input == null || input.isEmpty) return;
    try {
      String roomId;
      if (action == 'dm') {
        roomId = await client.startDirectChat(_mxid(input), enableEncryption: true);
      } else if (action == 'group') {
        roomId = await client.createGroupChat(groupName: input, enableEncryption: true, preset: CreateRoomPreset.privateChat);
      } else {
        roomId = await client.joinRoom(input.startsWith('#') || input.startsWith('!') ? input : '#$input');
      }
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

  String _mxid(String s) {
    s = s.trim();
    if (!s.startsWith('@')) s = '@$s';
    if (!s.contains(':')) s = '$s:${client.userID!.domain}';
    return s;
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
      return Row(children: [
        SizedBox(width: listW, child: _list(context)),
        VerticalDivider(width: 1, thickness: 1, color: Theme.of(context).dividerColor.withValues(alpha: 0.3)),
        Expanded(
          child: sel == null || sel.membership != Membership.join
              ? Container(
                  color: Bubbles.wall(context),
                  alignment: Alignment.center,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                    decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.25), borderRadius: BorderRadius.circular(14)),
                    child: const Text('Выберите чат', style: TextStyle(color: Colors.white)),
                  ),
                )
              : ChatPage(key: ValueKey('${sel.id}|$_jump'), room: sel, embedded: true, jumpTo: _jump),
        ),
      ]);
    });
  }

  Widget _list(BuildContext context) {
    final rooms = _rooms;
    final hint = Theme.of(context).hintColor;
    final accent = Theme.of(context).colorScheme.primary;
    return Scaffold(
      appBar: AppBar(
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
            : const Text('Ласточка', style: TextStyle(fontWeight: FontWeight.w600)),
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
          preferredSize: const Size.fromHeight(44),
          child: SizedBox(
            height: 44,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              children: [
                for (final (id, name) in [
                  ...builtinFolders,
                  for (final f in userFolders()) ('f:${f.id}', f.name),
                  if (client.rooms.any(isArchived)) ('archive', '🗄 Архив'),
                ])
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
                    child: GestureDetector(
                      onLongPress: id.startsWith('f:') ? () => _editFolder(userFolders().firstWhere((f) => 'f:${f.id}' == id)) : null,
                      child: ChoiceChip(
                        label: Text(name),
                        selected: _folder == id,
                        showCheckmark: false,
                        onSelected: (_) => setState(() => _folder = id),
                      ),
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
                  child: ActionChip(avatar: const Icon(Icons.add, size: 18), label: const Text('Папка'), tooltip: 'Новая папка (удерживайте папку, чтобы изменить)', onPressed: () => _editFolder()),
                ),
              ],
            ),
          ),
        ),
      ),
      drawer: _drawer(context),
      floatingActionButton: FloatingActionButton(onPressed: _newChat, tooltip: 'Новый чат', child: const Icon(Icons.edit_outlined)),
      body: Column(children: [
        const UpdateBanner(),
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
                    return ListTile(
                      selected: _wide && _selected?.id == r.id,
                      selectedTileColor: accent.withValues(alpha: 0.12),
                      selectedColor: Theme.of(context).textTheme.bodyLarge?.color,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      minVerticalPadding: 6,
                      leading: saved ? const SavedAvatar() : Avatar(mxc: r.avatar, name: name, size: 54),
                      title: Row(children: [
                        if (r.encrypted && r.isDirectChat) Padding(padding: const EdgeInsets.only(right: 3), child: Icon(Icons.lock, size: 14, color: Colors.green.shade600)),
                        Expanded(child: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16.5))),
                        if (muted) Padding(padding: const EdgeInsets.only(left: 3), child: Icon(Icons.volume_off, size: 15, color: hint)),
                        if (mineLast) Padding(padding: const EdgeInsets.only(left: 6), child: Icon(readLast ? Icons.done_all : Icons.done, size: 16, color: Colors.green.shade600)),
                        if (ts != null) Padding(padding: const EdgeInsets.only(left: 4), child: Text(shortTime(ts), style: TextStyle(fontSize: 12.5, color: unread > 0 && !muted ? accent : hint))),
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
                                    style: TextStyle(color: hint, fontSize: 15),
                                  )
                                : typing.isNotEmpty
                                ? Text(r.isDirectChat ? 'печатает…' : '${typing.first.calcDisplayname()} печатает…', maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: accent))
                                : Text(previewText(r), maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: hint, fontSize: 15)),
                          ),
                          if (r.isFavourite && unread == 0) Icon(Icons.push_pin, size: 16, color: hint),
                          if (unread > 0 || r.membership == Membership.invite)
                            Container(
                              margin: const EdgeInsets.only(left: 6),
                              constraints: const BoxConstraints(minWidth: 22),
                              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                              decoration: BoxDecoration(color: muted ? hint.withValues(alpha: 0.6) : accent, borderRadius: BorderRadius.circular(12)),
                              child: Text(unread > 0 ? '$unread' : '•', textAlign: TextAlign.center, style: const TextStyle(color: Colors.white, fontSize: 12.5, fontWeight: FontWeight.w600)),
                            ),
                        ]),
                      ),
                      onTap: () => _open(r),
                      onLongPress: () => _menu(r),
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
              margin: EdgeInsets.zero,
              decoration: BoxDecoration(color: Theme.of(context).brightness == Brightness.dark ? const Color(0xFF2B2B2B) : Theme.of(context).colorScheme.primary),
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
        ListTile(leading: const Icon(Icons.bookmark_outline), title: const Text(savedName), onTap: () async {
          Navigator.pop(context);
          try {
            final r = await openSaved();
            if (r != null && mounted) _open(r);
          } catch (_) {
            _toast('Не удалось открыть «Избранное»');
          }
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
          Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SettingsPage()));
        }),
      ]),
    );
  }
}
