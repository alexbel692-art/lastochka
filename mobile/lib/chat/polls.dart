// Опросы (стандарт Matrix MSC3381 — те же, что в Element): создание, голосование, итоги, завершение.
import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart';

import '../main.dart';
import 'autodelete.dart';

const pollStart = 'org.matrix.msc3381.poll.start';
const pollResponse = 'org.matrix.msc3381.poll.response';
const pollEnd = 'org.matrix.msc3381.poll.end';
const _kindDisclosed = 'org.matrix.msc3381.poll.disclosed';
const _kindUndisclosed = 'org.matrix.msc3381.poll.undisclosed';

bool isPollStart(Event e) => e.type == pollStart || e.type == 'm.poll.start';
bool _isResponse(Event e) => e.type == pollResponse || e.type == 'm.poll.response';
bool _isEnd(Event e) => e.type == pollEnd || e.type == 'm.poll.end';

String _text(Object? o) {
  if (o is String) return o;
  if (o is Map) {
    final t = o['org.matrix.msc1767.text'] ?? o['body'];
    if (t is String) return t;
    final list = o['m.text'] ?? o['org.matrix.msc1767.message'];
    if (list is List && list.isNotEmpty && list.first is Map) return '${(list.first as Map)['body'] ?? ''}';
  }
  return '';
}

class PollData {
  final String question;
  final List<(String, String)> answers; // id, текст
  final int maxSelections;
  final bool disclosed;
  PollData(this.question, this.answers, this.maxSelections, this.disclosed);

  static PollData? of(Event e) {
    final p = e.content[pollStart] ?? e.content['m.poll'];
    if (p is! Map) return null;
    final ans = <(String, String)>[];
    final list = p['answers'];
    if (list is List) {
      for (final a in list.take(20)) {
        if (a is Map && a['id'] is String) ans.add((a['id'] as String, _text(a)));
      }
    }
    final max = (p['max_selections'] as num?)?.toInt() ?? 1;
    return PollData(_text(p['question']), ans, max.clamp(1, ans.isEmpty ? 1 : ans.length), p['kind'] != _kindUndisclosed);
  }
}

String pollPreview(Event e) => '📊 ${PollData.of(e)?.question ?? 'Опрос'}';

Future<void> createPoll(BuildContext context, Room room) async {
  final q = TextEditingController();
  final answers = [TextEditingController(), TextEditingController()];
  var multi = false, anonymous = false;
  final ok = await showDialog<bool>(
    context: context,
    builder: (d) => StatefulBuilder(
      builder: (d, set) => AlertDialog(
        title: const Text('Новый опрос'),
        content: SizedBox(
          width: 420,
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(enableIMEPersonalizedLearning: false, controller: q, autofocus: true, maxLength: 300, decoration: const InputDecoration(hintText: 'Вопрос')),
              for (var i = 0; i < answers.length; i++)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: TextField(
                    enableIMEPersonalizedLearning: false,
                    controller: answers[i],
                    maxLength: 100,
                    decoration: InputDecoration(
                      hintText: 'Вариант ${i + 1}',
                      counterText: '',
                      suffixIcon: answers.length > 2 ? IconButton(icon: const Icon(Icons.close), onPressed: () => set(() => answers.removeAt(i))) : null,
                    ),
                  ),
                ),
              if (answers.length < 10)
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(onPressed: () => set(() => answers.add(TextEditingController())), icon: const Icon(Icons.add), label: const Text('Добавить вариант')),
                ),
              SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('Несколько ответов'), value: multi, onChanged: (v) => set(() => multi = v)),
              SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('Итоги — после завершения'), value: anonymous, onChanged: (v) => set(() => anonymous = v)),
            ]),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Отмена')),
          FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('Создать')),
        ],
      ),
    ),
  );
  final question = q.text.trim();
  final opts = answers.map((c) => c.text.trim()).where((t) => t.isNotEmpty).toList();
  if (ok != true) return;
  if (question.isEmpty || opts.length < 2) {
    if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Нужен вопрос и хотя бы два варианта')));
    return;
  }
  final fallback = '$question\n${[for (var i = 0; i < opts.length; i++) '${i + 1}. ${opts[i]}'].join('\n')}';
  await room.sendEvent({
    pollStart: {
      'question': {'org.matrix.msc1767.text': question, 'body': question, 'msgtype': 'm.text'},
      'kind': anonymous ? _kindUndisclosed : _kindDisclosed,
      'max_selections': multi ? opts.length : 1,
      'answers': [
        for (var i = 0; i < opts.length; i++) {'id': 'a$i', 'org.matrix.msc1767.text': opts[i]},
      ],
    },
    'org.matrix.msc1767.text': fallback,
    'body': fallback,
    ...ttlExtra(room),
  }, type: pollStart);
}

/// Итоги опроса по ответам в ленте.
class PollState {
  final Map<String, int> counts = {};
  final Set<String> mine = {};
  int voters = 0;
  Event? ended;
}

PollState pollState(Event start, Timeline tl, PollData p) {
  final refs = start.aggregatedEvents(tl, 'm.reference');
  final s = PollState();
  for (final e in refs) {
    if (_isEnd(e) && (e.senderId == start.senderId || (e.room.getPowerLevelByUserId(e.senderId) >= 50))) {
      if (s.ended == null || e.originServerTs.isBefore(s.ended!.originServerTs)) s.ended = e;
    }
  }
  final latest = <String, Event>{};
  for (final e in refs) {
    if (!_isResponse(e)) continue;
    if (s.ended != null && e.originServerTs.isAfter(s.ended!.originServerTs)) continue;
    final prev = latest[e.senderId];
    if (prev == null || e.originServerTs.isAfter(prev.originServerTs)) latest[e.senderId] = e;
  }
  final valid = p.answers.map((a) => a.$1).toSet();
  for (final MapEntry(key: user, value: e) in latest.entries) {
    final r = e.content[pollResponse] ?? e.content['m.selections'];
    final list = r is Map ? r['answers'] : r;
    if (list is! List) continue;
    final picked = list.whereType<String>().where(valid.contains).take(p.maxSelections).toSet();
    if (picked.isEmpty) continue;
    s.voters++;
    for (final a in picked) {
      s.counts[a] = (s.counts[a] ?? 0) + 1;
    }
    if (user == client.userID) s.mine.addAll(picked);
  }
  return s;
}

/// Когда опрос завершён (null — ещё идёт).
Event? pollStateOf(Event start, Timeline tl) {
  final p = PollData.of(start);
  return p == null ? null : pollState(start, tl, p).ended;
}

Future<void> endPoll(Room room, Event start) => room.sendEvent({
      'm.relates_to': {'rel_type': 'm.reference', 'event_id': start.eventId},
      pollEnd: <String, Object?>{},
      'org.matrix.msc1767.text': 'Опрос завершён',
      'body': 'Опрос завершён',
    }, type: pollEnd);

class PollView extends StatelessWidget {
  final Event event;
  final Timeline timeline;
  final Color accent;
  const PollView({super.key, required this.event, required this.timeline, required this.accent});

  Future<void> _vote(BuildContext context, PollData p, PollState s, String id) async {
    final next = Set<String>.of(s.mine);
    if (p.maxSelections == 1) {
      next
        ..clear()
        ..add(id);
      if (s.mine.contains(id)) next.clear(); // повторное нажатие — отменить голос
    } else {
      next.contains(id) ? next.remove(id) : next.add(id);
    }
    try {
      await event.room.sendEvent({
        'm.relates_to': {'rel_type': 'm.reference', 'event_id': event.eventId},
        pollResponse: {'answers': next.toList()},
      }, type: pollResponse);
    } catch (_) {
      if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Голос не отправлен')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = PollData.of(event);
    if (p == null) return const Text('Опрос');
    final s = pollState(event, timeline, p);
    final ended = s.ended != null;
    final showResults = ended || (p.disclosed && s.mine.isNotEmpty);
    final hint = Theme.of(context).hintColor;
    return ConstrainedBox(
      constraints: const BoxConstraints(minWidth: 240),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        Text(p.question, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16)),
        const SizedBox(height: 2),
        Text(
          '${ended ? 'Опрос завершён' : p.disclosed ? 'Опрос' : 'Итоги после завершения'}${p.maxSelections > 1 ? ' · несколько ответов' : ''}',
          style: TextStyle(fontSize: 12.5, color: hint),
        ),
        const SizedBox(height: 6),
        for (final (id, text) in p.answers)
          InkWell(
            onTap: ended ? null : () => _vote(context, p, s, id),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 5),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Icon(
                    s.mine.contains(id)
                        ? (p.maxSelections > 1 ? Icons.check_box : Icons.check_circle)
                        : (p.maxSelections > 1 ? Icons.check_box_outline_blank : Icons.radio_button_unchecked),
                    size: 20,
                    color: s.mine.contains(id) ? accent : hint,
                  ),
                  const SizedBox(width: 8),
                  Expanded(child: Text(text)),
                  if (showResults) Text('${s.voters == 0 ? 0 : ((s.counts[id] ?? 0) * 100 / s.voters).round()}%', style: const TextStyle(fontWeight: FontWeight.w600)),
                ]),
                if (showResults)
                  Padding(
                    padding: const EdgeInsets.only(left: 28, top: 3),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(3),
                      child: LinearProgressIndicator(
                        value: s.voters == 0 ? 0 : (s.counts[id] ?? 0) / s.voters,
                        minHeight: 4,
                        color: accent,
                        backgroundColor: accent.withValues(alpha: 0.15),
                      ),
                    ),
                  ),
              ]),
            ),
          ),
        Text(
          s.voters == 0 ? 'Пока никто не проголосовал' : 'Проголосовали: ${s.voters}',
          style: TextStyle(fontSize: 12.5, color: hint),
        ),
      ]),
    );
  }
}
