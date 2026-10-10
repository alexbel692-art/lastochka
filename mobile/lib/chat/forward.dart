// Пересылка сообщений в другие чаты (одного или сразу нескольких), с подписью «Переслано от …».
import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart';

import '../main.dart';
import '../widgets/avatar.dart';
import 'autodelete.dart';

const forwardedKey = 'ru.lastochka.forwarded';

/// Имя того, от кого переслано (если сообщение пересланное).
String? forwardedFrom(Event e) {
  final f = e.content[forwardedKey];
  if (f is! Map) return null;
  final n = f['name'];
  return n is String && n.isNotEmpty ? n : f['from'] is String ? f['from'] as String : null;
}

bool canForward(Event e) => !e.redacted && (e.type == EventTypes.Message || e.type == EventTypes.Sticker);

Map<String, Object?> _forwardContent(Event e, Timeline? tl, Room target) {
  final d = tl == null ? e : e.getDisplayEvent(tl);
  final c = Map<String, Object?>.from(d.content)
    ..remove('m.relates_to')
    ..remove('m.new_content')
    ..remove(expiresKey);
  c['m.mentions'] = <String, Object?>{}; // пересылка никого не упоминает заново
  if (d.messageType == MessageTypes.Text || d.messageType == MessageTypes.Notice || d.messageType == MessageTypes.Emote) {
    c['body'] = d.calcUnlocalizedBody(hideReply: true);
    final f = c['formatted_body'];
    if (f is String) c['formatted_body'] = f.replaceAll(RegExp(r'<mx-reply>[\s\S]*?</mx-reply>'), '');
  }
  // уже пересланное — сохраняем исходного автора
  c[forwardedKey] = e.content[forwardedKey] is Map
      ? e.content[forwardedKey]
      : {'from': e.senderId, 'name': e.senderFromMemoryOrFallback.calcDisplayname()};
  c.addAll(ttlExtra(target));
  return c;
}

Future<void> forwardEvents(BuildContext context, List<Event> events, Timeline? tl) async {
  final list = events.where(canForward).toList()..sort((a, b) => a.originServerTs.compareTo(b.originServerTs));
  if (list.isEmpty) return;
  final targets = await showDialog<List<Room>>(context: context, builder: (_) => const _PickRooms());
  if (targets == null || targets.isEmpty) return;
  var failed = 0;
  for (final r in targets) {
    for (final e in list) {
      try {
        await r.sendEvent(_forwardContent(e, tl, r), type: e.type == EventTypes.Sticker ? EventTypes.Sticker : EventTypes.Message);
      } catch (_) {
        failed++;
      }
    }
  }
  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(failed > 0 ? 'Не всё переслано — проверьте подключение' : targets.length == 1 ? 'Переслано в «${targets.first.getLocalizedDisplayname()}»' : 'Переслано в ${targets.length} чата(ов)'),
    ));
  }
}

class _PickRooms extends StatefulWidget {
  const _PickRooms();
  @override
  State<_PickRooms> createState() => _PickRoomsState();
}

class _PickRoomsState extends State<_PickRooms> {
  final _q = TextEditingController();
  final Set<String> _sel = {};

  @override
  Widget build(BuildContext context) {
    final q = _q.text.trim().toLowerCase();
    final rooms = client.rooms
        .where((r) => r.membership == Membership.join && r.canSendDefaultMessages)
        .where((r) => q.isEmpty || r.getLocalizedDisplayname().toLowerCase().contains(q))
        .toList();
    return AlertDialog(
      title: const Text('Переслать в…'),
      contentPadding: const EdgeInsets.fromLTRB(8, 12, 8, 0),
      content: SizedBox(
        width: 420,
        height: 460,
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: TextField(
              controller: _q,
              enableIMEPersonalizedLearning: false,
              decoration: const InputDecoration(hintText: 'Поиск', prefixIcon: Icon(Icons.search), isDense: true),
              onChanged: (_) => setState(() {}),
            ),
          ),
          const SizedBox(height: 6),
          Expanded(
            child: ListView.builder(
              itemCount: rooms.length,
              itemBuilder: (_, i) {
                final r = rooms[i];
                final name = r.getLocalizedDisplayname();
                return CheckboxListTile(
                  value: _sel.contains(r.id),
                  onChanged: (v) => setState(() => v == true ? _sel.add(r.id) : _sel.remove(r.id)),
                  secondary: Avatar(mxc: r.avatar, name: name, size: 40),
                  title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
                );
              },
            ),
          ),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Отмена')),
        FilledButton(
          onPressed: _sel.isEmpty ? null : () => Navigator.pop(context, client.rooms.where((r) => _sel.contains(r.id)).toList()),
          child: Text(_sel.isEmpty ? 'Отправить' : 'Отправить (${_sel.length})'),
        ),
      ],
    );
  }
}
