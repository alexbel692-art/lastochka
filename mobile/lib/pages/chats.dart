import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:matrix/matrix.dart';

import '../main.dart';
import '../theme.dart';
import '../widgets/avatar.dart';
import 'chat.dart';
import 'settings.dart';

String previewText(Room room) {
  final ev = room.lastEvent;
  if (room.membership == Membership.invite) return 'Приглашение в чат';
  if (ev == null) return '';
  if (ev.type == EventTypes.Encrypted) return '🔒 Зашифрованное сообщение';
  if (ev.redacted) return 'Сообщение удалено';
  String body;
  if (ev.type == EventTypes.Message || ev.type == EventTypes.Sticker) {
    body = switch (ev.messageType) {
      MessageTypes.Image => '🖼 Фото',
      MessageTypes.Video => '🎬 Видео',
      MessageTypes.Audio => '🎤 Голосовое сообщение',
      MessageTypes.File => '📎 ${ev.body}',
      MessageTypes.Sticker => 'Стикер',
      _ => ev.type == EventTypes.Sticker ? 'Стикер' : ev.body,
    };
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

enum Folder { all, direct, groups, unread }

const folderNames = {Folder.all: 'Все', Folder.direct: 'Личные', Folder.groups: 'Группы', Folder.unread: 'Непрочитанные'};

class ChatsPage extends StatefulWidget {
  const ChatsPage({super.key});
  @override
  State<ChatsPage> createState() => _ChatsPageState();
}

class _ChatsPageState extends State<ChatsPage> {
  StreamSubscription? _sub;
  Folder _folder = Folder.all;
  Room? _selected; // открытый чат справа (планшет)
  bool _wide = false;
  bool _searching = false;
  final _q = TextEditingController();

  @override
  void initState() {
    super.initState();
    _sub = client.onSync.stream.listen((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  List<Room> get _rooms {
    final q = _q.text.trim().toLowerCase();
    return client.rooms.where((r) {
      if (r.membership == Membership.leave || r.membership == Membership.ban) return false;
      if (q.isNotEmpty && !r.getLocalizedDisplayname().toLowerCase().contains(q)) return false;
      return switch (_folder) {
        Folder.all => true,
        Folder.direct => r.isDirectChat,
        Folder.groups => !r.isDirectChat,
        Folder.unread => r.isUnreadOrInvited,
      };
    }).toList();
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
        content: TextField(controller: c, autofocus: true, autocorrect: false, decoration: InputDecoration(hintText: hint), onSubmitted: (v) => Navigator.pop(d, v.trim())),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d), child: const Text('Отмена')),
          FilledButton(onPressed: () => Navigator.pop(d, c.text.trim()), child: const Text('Готово')),
        ],
      ),
    );
  }

  void _toast(String s) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s)));

  Future<void> _open(Room room) async {
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
    if (_wide) return setState(() => _selected = room);
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => ChatPage(room: room)));
  }

  Future<void> _menu(Room room) async {
    final fav = room.isFavourite;
    final muted = room.pushRuleState != PushRuleState.notify;
    final a = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (c) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(leading: Icon(fav ? Icons.push_pin : Icons.push_pin_outlined), title: Text(fav ? 'Открепить' : 'Закрепить'), onTap: () => Navigator.pop(c, 'fav')),
          ListTile(leading: Icon(muted ? Icons.notifications_outlined : Icons.notifications_off_outlined), title: Text(muted ? 'Включить уведомления' : 'Без звука'), onTap: () => Navigator.pop(c, 'mute')),
          ListTile(leading: const Icon(Icons.mark_chat_read_outlined), title: const Text('Отметить прочитанным'), onTap: () => Navigator.pop(c, 'read')),
          ListTile(leading: const Icon(Icons.logout, color: Colors.redAccent), title: const Text('Покинуть чат', style: TextStyle(color: Colors.redAccent)), onTap: () => Navigator.pop(c, 'leave')),
        ]),
      ),
    );
    try {
      switch (a) {
        case 'fav':
          await room.setFavourite(!fav);
        case 'mute':
          await room.setPushRuleState(muted ? PushRuleState.notify : PushRuleState.mentionsOnly);
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
              : ChatPage(key: ValueKey(sel.id), room: sel, embedded: true),
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
            ? TextField(
                controller: _q,
                autofocus: true,
                onChanged: (_) => setState(() {}),
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
              if (!_searching) _q.clear();
            }),
          ),
          IconButton(icon: const Icon(Icons.settings_outlined), onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SettingsPage()))),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(44),
          child: SizedBox(
            height: 44,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              children: [
                for (final f in Folder.values)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
                    child: ChoiceChip(
                      label: Text(folderNames[f]!),
                      selected: _folder == f,
                      showCheckmark: false,
                      onSelected: (_) => setState(() => _folder = f),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
      floatingActionButton: FloatingActionButton(onPressed: _newChat, child: const Icon(Icons.edit_outlined)),
      body: client.prevBatch == null && client.rooms.isEmpty
          ? const Center(child: CircularProgressIndicator())
          : rooms.isEmpty
              ? Center(child: Text(_q.text.isEmpty ? 'Здесь пока нет чатов' : 'Ничего не найдено', style: TextStyle(color: hint)))
              : ListView.builder(
                  itemCount: rooms.length,
                  itemBuilder: (_, i) {
                    final r = rooms[i];
                    final name = r.getLocalizedDisplayname();
                    final unread = r.notificationCount;
                    final muted = r.pushRuleState != PushRuleState.notify;
                    final ts = r.lastEvent?.originServerTs;
                    return ListTile(
                      selected: _wide && _selected?.id == r.id,
                      selectedTileColor: accent.withValues(alpha: 0.12),
                      selectedColor: Theme.of(context).textTheme.bodyLarge?.color,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
                      leading: Avatar(mxc: r.avatar, name: name),
                      title: Row(children: [
                        Expanded(child: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600))),
                        if (muted) Icon(Icons.volume_off, size: 14, color: hint),
                        if (ts != null) Padding(padding: const EdgeInsets.only(left: 6), child: Text(shortTime(ts), style: TextStyle(fontSize: 12, color: hint))),
                      ]),
                      subtitle: Row(children: [
                        Expanded(child: Text(previewText(r), maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: hint))),
                        if (r.isFavourite) Icon(Icons.push_pin, size: 14, color: hint),
                        if (unread > 0 || r.membership == Membership.invite)
                          Container(
                            margin: const EdgeInsets.only(left: 6),
                            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                            decoration: BoxDecoration(color: muted ? hint : accent, borderRadius: BorderRadius.circular(12)),
                            child: Text(unread > 0 ? '$unread' : '•', style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600)),
                          ),
                      ]),
                      onTap: () => _open(r),
                      onLongPress: () => _menu(r),
                    );
                  },
                ),
    );
  }
}
