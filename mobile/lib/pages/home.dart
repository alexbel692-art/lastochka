// Главный экран. Телефон: внизу «Контакты · Чаты · Звонки · Настройки», как в Telegram.
// Планшет и компьютер (широкий экран): список чатов слева, чат справа — без нижней панели.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:matrix/matrix.dart';

import '../calls/voip.dart';
import '../main.dart';
import '../system/diag.dart';
import '../widgets/avatar.dart';
import 'chat.dart';
import 'chats.dart';
import 'settings.dart';

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});
  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _tab = 1;
  final _seen = <int>{1}; // вкладки создаются при первом открытии

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, c) {
        if (c.maxWidth >= 720) return const ChatsPage();
        _seen.add(_tab);
        return Scaffold(
          body: IndexedStack(index: _tab, children: [
            _seen.contains(0) ? const ContactsPage() : const SizedBox.shrink(),
            const ChatsPage(),
            _seen.contains(2) ? const CallsPage() : const SizedBox.shrink(),
            _seen.contains(3) ? const SettingsPage() : const SizedBox.shrink(),
          ]),
          bottomNavigationBar: NavigationBar(
            selectedIndex: _tab,
            height: 64,
            labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
            onDestinationSelected: (i) => setState(() => _tab = i),
            destinations: const [
              NavigationDestination(icon: Icon(Icons.person_outline_rounded), selectedIcon: Icon(Icons.person_rounded), label: 'Контакты'),
              NavigationDestination(icon: Icon(Icons.chat_bubble_outline_rounded), selectedIcon: Icon(Icons.chat_bubble_rounded), label: 'Чаты'),
              NavigationDestination(icon: Icon(Icons.call_outlined), selectedIcon: Icon(Icons.call_rounded), label: 'Звонки'),
              NavigationDestination(icon: Icon(Icons.settings_outlined), selectedIcon: Icon(Icons.settings_rounded), label: 'Настройки'),
            ],
          ),
        );
      });
}

Future<void> _openDm(BuildContext context, String userId) async {
  try {
    final id = client.getDirectChatFromUserId(userId) ?? await client.startDirectChat(userId, enableEncryption: true);
    final room = client.getRoomById(id) ?? await client.waitForRoomInSync(id).then((_) => client.getRoomById(id));
    if (room != null && context.mounted) await Navigator.of(context).push(MaterialPageRoute(builder: (_) => ChatPage(room: room)));
  } catch (e) {
    Diag.err('Открытие личного чата', e);
    if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Не удалось открыть чат')));
  }
}

// ---------------- Контакты ----------------

class ContactsPage extends StatefulWidget {
  const ContactsPage({super.key});
  @override
  State<ContactsPage> createState() => _ContactsPageState();
}

class _ContactsPageState extends State<ContactsPage> {
  final _q = TextEditingController();
  final Map<String, Profile> _found = {};
  Timer? _t;

  @override
  void dispose() {
    _t?.cancel();
    _q.dispose();
    super.dispose();
  }

  /// Люди из личных чатов — первыми, затем участники общих групп.
  List<(String, String, Uri?, bool)> get _people {
    final q = _q.text.trim().toLowerCase();
    final out = <String, (String, String, Uri?, bool)>{};
    for (final r in client.rooms) {
      if (r.membership != Membership.join) continue;
      final dm = r.isDirectChat ? r.directChatMatrixID : null;
      if (dm != null) {
        final u = r.unsafeGetUserFromMemoryOrFallback(dm);
        out[dm] = (dm, u.calcDisplayname(), u.avatarUrl, true);
      }
    }
    for (final r in client.rooms) {
      if (r.membership != Membership.join || r.isDirectChat) continue;
      for (final u in r.getParticipants([Membership.join])) {
        if (u.id == client.userID || out.containsKey(u.id)) continue;
        out[u.id] = (u.id, u.calcDisplayname(), u.avatarUrl, false);
      }
    }
    for (final p in _found.values) {
      if (p.userId == client.userID || out.containsKey(p.userId)) continue;
      out[p.userId] = (p.userId, p.displayName ?? p.userId.localpart ?? p.userId, p.avatarUrl, false);
    }
    final list = out.values.where((p) => q.isEmpty || p.$2.toLowerCase().contains(q) || p.$1.toLowerCase().contains(q)).toList()
      ..sort((a, b) => a.$4 != b.$4 ? (a.$4 ? -1 : 1) : a.$2.toLowerCase().compareTo(b.$2.toLowerCase()));
    return list;
  }

  void _search(String q) {
    setState(() {});
    _t?.cancel();
    if (q.trim().length < 2) return;
    _t = Timer(const Duration(milliseconds: 350), () async {
      try {
        final r = await client.searchUserDirectory(q.trim(), limit: 30);
        if (!mounted) return;
        setState(() {
          for (final p in r.results) {
            _found[p.userId] = p;
          }
        });
      } catch (_) {}
    });
  }

  @override
  Widget build(BuildContext context) {
    final people = _people;
    final hint = Theme.of(context).hintColor;
    final accent = Theme.of(context).colorScheme.primary;
    return Scaffold(
      appBar: AppBar(title: const Text('Контакты', style: TextStyle(fontWeight: FontWeight.w600))),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 6),
          child: TextField(
            controller: _q,
            enableIMEPersonalizedLearning: false,
            autocorrect: false,
            onChanged: _search,
            decoration: InputDecoration(hintText: 'Поиск по имени или логину', prefixIcon: const Icon(Icons.search), isDense: true,
                suffixIcon: _q.text.isEmpty ? null : IconButton(icon: const Icon(Icons.close), onPressed: () => setState(_q.clear))),
          ),
        ),
        Expanded(
          child: people.isEmpty
              ? Center(child: Text(_q.text.isEmpty ? 'Здесь появятся люди из ваших чатов' : 'Никого не нашлось', style: TextStyle(color: hint)))
              : ListView.builder(
                  itemCount: people.length,
                  itemBuilder: (_, i) {
                    final (id, name, av, dm) = people[i];
                    return ListTile(
                      leading: Avatar(mxc: av, name: name, size: 46),
                      title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w500)),
                      subtitle: Text(id.domain == client.userID?.domain ? (id.localpart ?? id) : id, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: hint, fontSize: 13)),
                      trailing: dm
                          ? IconButton(
                              tooltip: 'Позвонить',
                              icon: Icon(Icons.call_outlined, color: accent),
                              onPressed: () {
                                final room = client.getRoomById(client.getDirectChatFromUserId(id) ?? '');
                                if (room != null) startCall(context, room, video: false);
                              },
                            )
                          : null,
                      onTap: () => _openDm(context, id),
                    );
                  },
                ),
        ),
      ]),
    );
  }
}

// ---------------- Звонки ----------------

class _CallItem {
  final Room room;
  final Event invite;
  final bool mine, missed, video;
  _CallItem(this.room, this.invite, this.mine, this.missed, this.video);
}

class CallsPage extends StatefulWidget {
  const CallsPage({super.key});
  @override
  State<CallsPage> createState() => _CallsPageState();
}

class _CallsPageState extends State<CallsPage> {
  List<_CallItem>? _items;

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// История звонков — из истории чатов на устройстве (расшифровывать ничего не нужно: события звонков не шифруются).
  Future<void> _load() async {
    final out = <_CallItem>[];
    final rooms = client.rooms.where((r) => r.membership == Membership.join).toList()
      ..sort((a, b) => (b.lastEvent?.originServerTs ?? DateTime(2000)).compareTo(a.lastEvent?.originServerTs ?? DateTime(2000)));
    for (final room in rooms.take(60)) {
      try {
        final tl = await room.getTimeline(limit: 150);
        final answered = <String>{};
        for (final e in tl.events) {
          if (e.type == EventTypes.CallAnswer) answered.add('${e.content['call_id']}');
        }
        for (final e in tl.events) {
          if (e.type != EventTypes.CallInvite) continue;
          final mine = e.senderId == client.userID;
          final sdp = '${(e.content['offer'] as Map?)?['sdp'] ?? ''}';
          out.add(_CallItem(room, e, mine, !mine && !answered.contains('${e.content['call_id']}'), sdp.contains('m=video')));
        }
        tl.cancelSubscriptions();
      } catch (e) {
        Diag.err('История звонков', e);
      }
    }
    out.sort((a, b) => b.invite.originServerTs.compareTo(a.invite.originServerTs));
    if (mounted) setState(() => _items = out);
  }

  @override
  Widget build(BuildContext context) {
    final items = _items;
    final hint = Theme.of(context).hintColor;
    return Scaffold(
      appBar: AppBar(title: const Text('Звонки', style: TextStyle(fontWeight: FontWeight.w600))),
      body: items == null
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: items.isEmpty
                  ? ListView(children: [const SizedBox(height: 120), Center(child: Text('Звонков пока не было', style: TextStyle(color: hint)))])
                  : ListView.builder(
                      itemCount: items.length,
                      itemBuilder: (_, i) {
                        final c = items[i];
                        final name = c.room.getLocalizedDisplayname();
                        final color = c.missed ? Colors.redAccent : (c.mine ? Colors.green : Theme.of(context).colorScheme.primary);
                        return ListTile(
                          leading: Avatar(mxc: c.room.avatar, name: name, size: 46),
                          title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontWeight: FontWeight.w500, color: c.missed ? Colors.redAccent : null)),
                          subtitle: Row(children: [
                            Icon(c.missed ? Icons.call_missed_rounded : (c.mine ? Icons.call_made_rounded : Icons.call_received_rounded), size: 16, color: color),
                            const SizedBox(width: 4),
                            Flexible(
                              child: Text(
                                '${c.missed ? 'Пропущенный' : c.mine ? 'Исходящий' : 'Входящий'}${c.video ? ' видео' : ''} · ${DateFormat('d MMM, HH:mm', 'ru').format(c.invite.originServerTs)}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(color: hint, fontSize: 13),
                              ),
                            ),
                          ]),
                          trailing: canCall(c.room)
                              ? IconButton(
                                  tooltip: c.video ? 'Видеозвонок' : 'Позвонить',
                                  icon: Icon(c.video ? Icons.videocam_outlined : Icons.call_outlined, color: Theme.of(context).colorScheme.primary),
                                  onPressed: () => startCall(context, c.room, video: c.video),
                                )
                              : null,
                          onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => ChatPage(room: c.room))),
                        );
                      },
                    ),
            ),
    );
  }
}
