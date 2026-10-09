import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart';

import '../calls/voip.dart';
import '../chat/autodelete.dart';
import '../system/trust.dart';
import 'verify.dart';
import '../main.dart';
import '../widgets/avatar.dart';

/// Информация о чате (как профиль в Telegram): звонки, уведомления, участники, выход.
class RoomInfoPage extends StatefulWidget {
  final Room room;
  const RoomInfoPage({super.key, required this.room});
  @override
  State<RoomInfoPage> createState() => _RoomInfoPageState();
}

class _RoomInfoPageState extends State<RoomInfoPage> {
  Room get room => widget.room;
  List<User>? _members;

  @override
  void initState() {
    super.initState();
    room.requestParticipants().then((m) => mounted ? setState(() => _members = m.where((u) => u.membership == Membership.join).toList()) : null).catchError((_) {});
  }

  void _toast(String s) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s)));

  Widget _action(IconData i, String label, VoidCallback onTap) => Expanded(
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Column(children: [
              Icon(i, color: Theme.of(context).colorScheme.primary),
              const SizedBox(height: 4),
              Text(label, style: TextStyle(fontSize: 13, color: Theme.of(context).colorScheme.primary)),
            ]),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final name = room.getLocalizedDisplayname();
    final muted = room.pushRuleState != PushRuleState.notify;
    final hint = Theme.of(context).hintColor;
    final topic = room.topic;
    final members = _members ?? room.getParticipants([Membership.join]);
    return Scaffold(
      appBar: AppBar(title: Text(room.isDirectChat ? 'Профиль' : 'Информация')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: ListView(children: [
            const SizedBox(height: 16),
            Center(child: Avatar(mxc: room.avatar, name: name, size: 110)),
            const SizedBox(height: 12),
            Text(name, textAlign: TextAlign.center, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            Text(
              room.isDirectChat ? (room.encrypted ? '🔒 Защищённый чат' : 'Личный чат') : '${members.length} участн.${room.encrypted ? ' · 🔒 защищён' : ''}',
              textAlign: TextAlign.center,
              style: TextStyle(color: hint),
            ),
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(children: [
                if (canCall(room)) ...[
                  _action(Icons.call_outlined, 'Звонок', () => startCall(context, room, video: false)),
                  _action(Icons.videocam_outlined, 'Видео', () => startCall(context, room, video: true)),
                ],
                _action(muted ? Icons.notifications_off_outlined : Icons.notifications_outlined, muted ? 'Без звука' : 'Звук', () async {
                  try {
                    await room.setPushRuleState(muted ? PushRuleState.notify : PushRuleState.mentionsOnly);
                    setState(() {});
                  } catch (_) {
                    _toast('Не получилось');
                  }
                }),
              ]),
            ),
            if (topic.isNotEmpty) ...[
              const Divider(),
              ListTile(leading: Icon(Icons.info_outline, color: hint), title: Text(topic), subtitle: const Text('Описание')),
            ],
            if (room.isDirectChat && room.directChatMatrixID != null)
              Builder(builder: (context) {
                final uid = room.directChatMatrixID!;
                final ok = Trust.instance.userVerified(uid);
                return ListTile(
                  leading: Icon(ok ? Icons.verified_user : Icons.shield_outlined, color: ok ? Colors.green : hint),
                  title: Text(ok ? 'Собеседник подтверждён' : 'Подтвердить собеседника'),
                  subtitle: Text(ok
                      ? 'Вы сравнили эмодзи — переписку не подменить незаметно'
                      : 'Сравните эмодзи на ваших устройствах — так вы убедитесь, что переписываетесь именно с ним'),
                  onTap: ok
                      ? null
                      : () async {
                          await verifyUser(context, uid);
                          if (mounted) setState(() {});
                        },
                );
              }),
            ListTile(
              leading: Icon(Icons.local_fire_department_outlined, color: roomTtl(room) > 0 ? Colors.deepOrange : hint),
              title: const Text('Автоудаление сообщений'),
              subtitle: Text(roomTtl(room) > 0 ? 'Новые сообщения исчезают через ${ttlText(roomTtl(room)).toLowerCase()}' : 'Выключено'),
              onTap: _ttlDialog,
            ),
            if (room.pinnedEventIds.isNotEmpty)
              ListTile(leading: Icon(Icons.push_pin_outlined, color: hint), title: Text('Закреплённых сообщений: ${room.pinnedEventIds.length}')),
            if (!room.isDirectChat) ...[
              const Divider(),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                child: Text('Участники', style: TextStyle(color: Theme.of(context).colorScheme.primary, fontWeight: FontWeight.w600)),
              ),
              if (room.canInvite)
                ListTile(
                  leading: CircleAvatar(backgroundColor: Theme.of(context).colorScheme.primary.withValues(alpha: 0.12), child: Icon(Icons.person_add_alt, color: Theme.of(context).colorScheme.primary)),
                  title: Text('Пригласить', style: TextStyle(color: Theme.of(context).colorScheme.primary)),
                  onTap: _invite,
                ),
              for (final u in members)
                ListTile(
                  leading: Avatar(mxc: u.avatarUrl, name: u.calcDisplayname(), size: 42),
                  title: Row(children: [
                    Flexible(child: Text(u.calcDisplayname() + (u.id == client.userID ? ' (вы)' : ''))),
                    if (Trust.instance.userVerified(u.id)) const Padding(padding: EdgeInsets.only(left: 4), child: Icon(Icons.verified_user, size: 15, color: Colors.green)),
                    if (Trust.instance.changed.value.containsKey(u.id)) const Padding(padding: EdgeInsets.only(left: 4), child: Icon(Icons.gpp_bad, size: 15, color: Colors.red)),
                  ]),
                  onTap: u.id == client.userID || Trust.instance.userVerified(u.id)
                      ? null
                      : () async {
                          await verifyUser(context, u.id);
                          if (mounted) setState(() {});
                        },
                  subtitle: u.powerLevel.level >= 100 ? const Text('администратор') : u.powerLevel.level >= 50 ? const Text('модератор') : null,
                ),
            ],
            const Divider(),
            ListTile(
              leading: const Icon(Icons.logout, color: Colors.redAccent),
              title: Text(room.isDirectChat ? 'Удалить чат' : 'Покинуть группу', style: const TextStyle(color: Colors.redAccent)),
              onTap: () async {
                final ok = await showDialog<bool>(
                  context: context,
                  builder: (d) => AlertDialog(
                    title: Text(room.isDirectChat ? 'Удалить чат?' : 'Покинуть группу?'),
                    actions: [
                      TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Отмена')),
                      TextButton(onPressed: () => Navigator.pop(d, true), child: const Text('Да', style: TextStyle(color: Colors.redAccent))),
                    ],
                  ),
                );
                if (ok != true) return;
                try {
                  await room.leave();
                  if (mounted) Navigator.of(context).popUntil((r) => r.isFirst);
                } catch (_) {
                  _toast('Не получилось');
                }
              },
            ),
            const SizedBox(height: 24),
          ]),
        ),
      ),
    );
  }

  Future<void> _invite() async {
    final c = TextEditingController();
    final v = await showDialog<String>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('Пригласить'),
        content: TextField(controller: c, autofocus: true, decoration: const InputDecoration(hintText: '@имя:сервер или имя')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d), child: const Text('Отмена')),
          FilledButton(onPressed: () => Navigator.pop(d, c.text.trim()), child: const Text('Пригласить')),
        ],
      ),
    );
    if (v == null || v.isEmpty) return;
    var id = v.startsWith('@') ? v : '@$v';
    if (!id.contains(':')) id = '$id:${client.userID!.domain}';
    try {
      await room.invite(id);
      _toast('Приглашение отправлено');
    } on MatrixException catch (e) {
      _toast(e.errcode == 'M_NOT_FOUND' ? 'Пользователь не найден' : e.errorMessage);
    } catch (_) {
      _toast('Не получилось');
    }
  }

  Future<void> _ttlDialog() async {
    final cur = roomTtl(room);
    final v = await showDialog<int>(
      context: context,
      builder: (d) => SimpleDialog(
        title: const Text('Автоудаление сообщений'),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
            child: Text('Новые сообщения будут исчезать у всех участников через выбранное время после отправки. Если на сервере включён срок хранения, он тоже будет стирать историю чата старше этого времени.',
                style: TextStyle(color: Theme.of(context).hintColor, fontSize: 13.5)),
          ),
          for (final (ms, t) in ttlOptions)
            RadioListTile<int>(value: ms, groupValue: cur, title: Text(t), onChanged: (x) => Navigator.pop(d, x)),
        ],
      ),
    );
    if (v == null || v == cur) return;
    try {
      await setRoomTtl(room, v);
      _toast(v > 0 ? 'Автоудаление: ${ttlText(v)}' : 'Автоудаление выключено');
      if (mounted) setState(() {});
    } catch (_) {
      _toast('Нет прав менять настройки этого чата');
    }
  }
}
