import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart';

import 'package:image_picker/image_picker.dart';

import '../calls/voip.dart';
import '../system/media_clean.dart';
import 'chat.dart';
import 'qr.dart';
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
            Center(
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: _canEdit(EventTypes.RoomAvatar) ? _changeAvatar : null,
                child: Avatar(mxc: room.avatar, name: name, size: 110),
              ),
            ),
            const SizedBox(height: 12),
            InkWell(
              onTap: _canEdit(EventTypes.RoomName) ? _changeName : null,
              child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                Flexible(child: Text(name, textAlign: TextAlign.center, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w600))),
                if (_canEdit(EventTypes.RoomName)) Padding(padding: const EdgeInsets.only(left: 6), child: Icon(Icons.edit_outlined, size: 18, color: hint)),
              ]),
            ),
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
            if (topic.isNotEmpty || _canEdit(EventTypes.RoomTopic)) ...[
              const Divider(),
              ListTile(
                leading: Icon(Icons.info_outline, color: hint),
                title: Text(topic.isEmpty ? 'Добавить описание' : topic),
                subtitle: const Text('Описание'),
                onTap: _canEdit(EventTypes.RoomTopic) ? _changeTopic : null,
              ),
            ],
            if (!room.isDirectChat) ...[
              if (_canEdit(EventTypes.RoomJoinRules))
                SwitchListTile(
                  secondary: Icon(Icons.link, color: hint),
                  title: const Text('Вход по ссылке и QR-коду'),
                  subtitle: const Text('Вступить сможет любой, у кого есть ссылка. Иначе — только по приглашению'),
                  value: room.joinRules == JoinRules.public,
                  onChanged: (v) async {
                    try {
                      await room.setJoinRules(v ? JoinRules.public : JoinRules.invite);
                      await Future.delayed(const Duration(milliseconds: 600));
                      if (mounted) setState(() {});
                    } catch (_) {
                      _toast('Не получилось');
                    }
                  },
                ),
              if (room.joinRules == JoinRules.public)
                ListTile(
                  leading: Icon(Icons.qr_code_2, color: hint),
                  title: const Text('QR-код группы'),
                  onTap: () => showQr(context, name, roomLink(room), note: 'Отсканируйте в Ласточке, чтобы вступить'),
                ),
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
                  onTap: u.id == client.userID ? null : () => _member(u),
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

  bool _canEdit(String type) => !room.isDirectChat && room.canChangeStateEvent(type);

  Future<String?> _ask(String title, String initial, {int max = 255, int lines = 1}) {
    final c = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text(title),
        content: TextField(enableIMEPersonalizedLearning: false, controller: c, autofocus: true, maxLength: max, maxLines: lines),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d), child: const Text('Отмена')),
          FilledButton(onPressed: () => Navigator.pop(d, c.text.trim()), child: const Text('Сохранить')),
        ],
      ),
    );
  }

  Future<void> _changeName() async {
    final v = await _ask('Название группы', room.getLocalizedDisplayname(), max: 64);
    if (v == null || v.isEmpty) return;
    try {
      await room.setName(v);
    } catch (_) {
      _toast('Не получилось');
    }
    if (mounted) setState(() {});
  }

  Future<void> _changeTopic() async {
    final v = await _ask('Описание группы', room.topic, max: 500, lines: 4);
    if (v == null) return;
    try {
      await room.setDescription(v);
    } catch (_) {
      _toast('Не получилось');
    }
    if (mounted) setState(() {});
  }

  Future<void> _changeAvatar() async {
    final x = await ImagePicker().pickImage(source: ImageSource.gallery, imageQuality: 95, maxWidth: 1024, requestFullMetadata: false);
    if (x == null) return;
    try {
      final clean = await cleanPhoto(await x.readAsBytes(), x.name);
      await room.setAvatar(MatrixFile(bytes: clean.bytes, name: clean.name));
    } catch (_) {
      _toast('Не удалось сменить фото');
    }
    if (mounted) setState(() {});
  }

  /// Действия с участником: написать, подтвердить, права, удалить, заблокировать.
  Future<void> _member(User u) async {
    final mine = room.ownPowerLevel.level;
    final theirs = u.powerLevel.level;
    final above = mine > theirs;
    final canPower = above && room.canChangeStateEvent(EventTypes.RoomPowerLevels);
    final a = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (c) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(leading: Avatar(mxc: u.avatarUrl, name: u.calcDisplayname(), size: 40), title: Text(u.calcDisplayname()), subtitle: Text(u.id)),
          ListTile(leading: const Icon(Icons.chat_outlined), title: const Text('Написать'), onTap: () => Navigator.pop(c, 'dm')),
          if (!Trust.instance.userVerified(u.id)) ListTile(leading: const Icon(Icons.verified_user_outlined), title: const Text('Подтвердить'), onTap: () => Navigator.pop(c, 'verify')),
          if (canPower && theirs < 100 && mine >= 100) ListTile(leading: const Icon(Icons.admin_panel_settings_outlined), title: const Text('Сделать администратором'), onTap: () => Navigator.pop(c, 'p100')),
          if (canPower && theirs < 50 && mine >= 50) ListTile(leading: const Icon(Icons.shield_outlined), title: const Text('Сделать модератором'), onTap: () => Navigator.pop(c, 'p50')),
          if (canPower && theirs > 0) ListTile(leading: const Icon(Icons.remove_moderator_outlined), title: const Text('Снять права'), onTap: () => Navigator.pop(c, 'p0')),
          if (above && room.canKick) ListTile(leading: const Icon(Icons.person_remove_outlined, color: Colors.redAccent), title: const Text('Удалить из группы', style: TextStyle(color: Colors.redAccent)), onTap: () => Navigator.pop(c, 'kick')),
          if (above && room.canBan) ListTile(leading: const Icon(Icons.block, color: Colors.redAccent), title: const Text('Заблокировать', style: TextStyle(color: Colors.redAccent)), onTap: () => Navigator.pop(c, 'ban')),
        ]),
      ),
    );
    if (a == null || !mounted) return;
    try {
      switch (a) {
        case 'dm':
          final id = await client.startDirectChat(u.id, enableEncryption: true);
          final r = client.getRoomById(id) ?? await client.waitForRoomInSync(id).then((_) => client.getRoomById(id));
          if (r != null && mounted) await Navigator.of(context).push(MaterialPageRoute(builder: (_) => ChatPage(room: r)));
        case 'verify':
          await verifyUser(context, u.id);
        case 'p100' || 'p50' || 'p0':
          if (a == 'p100' && !await _confirm('Сделать администратором?', 'Администратора нельзя будет понизить — у него будут те же права, что у вас.')) return;
          await room.setPower(u.id, int.parse(a.substring(1)));
        case 'kick':
          if (!await _confirm('Удалить ${u.calcDisplayname()} из группы?', 'Он(а) сможет вернуться, только если его снова пригласят.')) return;
          await room.kick(u.id);
        case 'ban':
          if (!await _confirm('Заблокировать ${u.calcDisplayname()}?', 'Он(а) будет удалён(а) из группы и не сможет вернуться, пока его не разблокируют.')) return;
          await room.ban(u.id);
      }
      _toast('Готово');
    } catch (_) {
      _toast('Не получилось — не хватает прав?');
    }
    final m = await room.requestParticipants().catchError((_) => <User>[]);
    if (mounted) setState(() => _members = m.where((x) => x.membership == Membership.join).toList());
  }

  Future<bool> _confirm(String title, String text) async =>
      await showDialog<bool>(
        context: context,
        builder: (d) => AlertDialog(
          title: Text(title),
          content: Text(text),
          actions: [
            TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Отмена')),
            FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('Да')),
          ],
        ),
      ) ==
      true;

  Future<void> _invite() async {
    final c = TextEditingController();
    final v = await showDialog<String>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('Пригласить'),
        content: TextField(enableIMEPersonalizedLearning: false, controller: c, autofocus: true, decoration: const InputDecoration(hintText: '@имя:сервер или имя')),
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
