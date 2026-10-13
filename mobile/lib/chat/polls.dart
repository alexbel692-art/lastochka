// Опросы (стандарт Matrix MSC3381 — те же, что в Element): создание, голосование, итоги, завершение.
import 'dart:async';

import 'package:flutter/foundation.dart' show setEquals;
import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../system/trust.dart';
import '../main.dart';
import '../system/diag.dart';
import '../system/notify.dart';
import '../system/secure_store.dart';
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

const pollEndsKey = 'ru.lastochka.poll_ends'; // когда опрос закрывается сам (мс)

class PollData {
  final String question;
  final List<(String, String)> answers; // id, текст
  final int maxSelections;
  final bool disclosed;
  final DateTime? endsAt;
  PollData(this.question, this.answers, this.maxSelections, this.disclosed, [this.endsAt]);

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
    final ends = (e.content[pollEndsKey] as num?)?.toInt();
    return PollData(_text(p['question']), ans, max.clamp(1, ans.isEmpty ? 1 : ans.length), p['kind'] != _kindUndisclosed,
        ends == null ? null : DateTime.fromMillisecondsSinceEpoch(ends));
  }
}

String pollPreview(Event e) => '📊 ${PollData.of(e)?.question ?? 'Опрос'}';

Future<void> createPoll(BuildContext context, Room room) async {
  final q = TextEditingController();
  final answers = [TextEditingController(), TextEditingController()];
  var multi = false, anonymous = false;
  var duration = Duration.zero; // без срока
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
              const SizedBox(height: 4),
              Align(alignment: Alignment.centerLeft, child: Text('Сколько длится опрос', style: TextStyle(color: Theme.of(d).hintColor, fontSize: 13))),
              const SizedBox(height: 6),
              Wrap(spacing: 6, runSpacing: 6, children: [
                for (final (dur, label) in pollDurations)
                  ChoiceChip(label: Text(label), selected: duration == dur, showCheckmark: false, onSelected: (_) => set(() => duration = dur)),
              ]),
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
  final endsAt = duration == Duration.zero ? null : DateTime.now().add(duration);
  final fallback = '$question\n${[for (var i = 0; i < opts.length; i++) '${i + 1}. ${opts[i]}'].join('\n')}';
  ensureCanSend(room);
  final id = await room.sendEvent({
    if (endsAt != null) pollEndsKey: endsAt.millisecondsSinceEpoch,
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
  // закрыть опрос в срок будет устройство автора (остальные просто перестают принимать голоса)
  if (id != null && endsAt != null) await _scheduleClose(room.id, id, endsAt);
}

const pollDurations = [
  (Duration.zero, 'Без срока'),
  (Duration(minutes: 15), '15 мин'),
  (Duration(hours: 1), '1 час'),
  (Duration(hours: 3), '3 часа'),
  (Duration(days: 1), '1 день'),
  (Duration(days: 3), '3 дня'),
  (Duration(days: 7), 'Неделя'),
];

const _closeKey = 'poll.autoClose';

// список хранится зашифрованным (какие опросы и в каких чатах — тоже сведения о переписке)
Future<List<String>> _loadClose() async {
  final prefs = await SharedPreferences.getInstance();
  final old = prefs.getStringList(_closeKey);
  final v = await SecureStore.instance.read(_closeKey);
  final list = v is List ? v.whereType<String>().toList() : <String>[];
  if (old != null) {
    // перенос из открытых настроек (до 4.12)
    list.addAll(old);
    await prefs.remove(_closeKey);
    await SecureStore.instance.write(_closeKey, list);
  }
  return list;
}

Future<void> _scheduleClose(String roomId, String eventId, DateTime at) async {
  final list = await _loadClose();
  list.add('$roomId|$eventId|${at.millisecondsSinceEpoch}');
  await SecureStore.instance.write(_closeKey, list);
  _pollTimer ??= Timer.periodic(const Duration(seconds: 30), (_) => closeDuePolls());
}

Timer? _pollTimer;

/// Запустить проверку опросов со сроком (при запуске приложения).
void startPollCloser() {
  _pollTimer ??= Timer.periodic(const Duration(seconds: 30), (_) => closeDuePolls());
  closeDuePolls();
}

bool _closing = false;

/// Завершить опросы, у которых вышел срок, и сообщить автору итоги.
Future<void> closeDuePolls() async {
  if (_closing || !client.isLogged()) return;
  _closing = true;
  try {
    final list = await _loadClose();
    if (list.isEmpty) return;
    final keep = <String>[];
    for (final item in list) {
      final parts = item.split('|');
      if (parts.length != 3) continue;
      final at = int.tryParse(parts[2]) ?? 0;
      if (DateTime.now().millisecondsSinceEpoch < at) {
        keep.add(item);
        continue;
      }
      final room = client.getRoomById(parts[0]);
      if (room == null) continue;
      try {
        final ev = await room.getEventById(parts[1]);
        if (ev == null || ev.redacted) continue;
        await endPoll(room, ev);
        await _notifyResults(room, ev);
      } catch (e) {
        Diag.err('Завершение опроса', e);
        keep.add(item); // попробуем ещё раз позже
      }
    }
    if (keep.length != list.length) await SecureStore.instance.write(_closeKey, keep.isEmpty ? null : keep);
  } catch (e) {
    Diag.err('Опросы со сроком', e);
  } finally {
    _closing = false;
  }
}

Future<void> _notifyResults(Room room, Event start) async {
  final p = PollData.of(start);
  if (p == null) return;
  var body = 'Откройте чат «${room.getLocalizedDisplayname()}», чтобы посмотреть итоги';
  try {
    final tl = await room.getTimeline();
    final s = pollState(start, tl, p);
    tl.cancelSubscriptions();
    if (s.voters > 0) {
      final ranked = [...p.answers]..sort((a, b) => (s.counts[b.$1] ?? 0).compareTo(s.counts[a.$1] ?? 0));
      final top = ranked.first;
      body = 'Лидер: «${top.$2}» — ${s.counts[top.$1] ?? 0} из ${s.voters}. Проголосовали: ${s.voters}';
    } else {
      body = 'Никто не проголосовал';
    }
  } catch (_) {}
  await showSecurityNotification('Опрос завершён: ${p.question}', body);
}

/// Мой последний выбор в опросе (по id опроса) — пока сервер не вернул его в ленту.
/// Сравнивать голоса по времени отправки ненадёжно: если часы телефона отстают от сервера,
/// новый голос выглядел «старше» прежнего и проигрывал — переголосовать не получалось.
final _myPick = <String, Set<String>>{};
final _myPickAt = <String, DateTime>{};
final pollChanged = ValueNotifier<int>(0);

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
    if (_isEnd(e) && (e.senderId == start.senderId || (e.room.getPowerLevelByUserId(e.senderId).level >= 50))) {
      if (s.ended == null || e.originServerTs.isBefore(s.ended!.originServerTs)) s.ended = e;
    }
  }
  final latest = <String, Event>{};
  for (final e in refs) {
    if (!_isResponse(e)) continue;
    if (e.status.isError) continue; // не отправился — не считаем
    if (s.ended != null && e.originServerTs.isAfter(s.ended!.originServerTs)) continue;
    if (p.endsAt != null && e.originServerTs.isAfter(p.endsAt!)) continue; // проголосовал после срока
    final prev = latest[e.senderId];
    // отправляемый сейчас голос — всегда самый новый, даже если часы телефона отстают
    final newer = prev == null ||
        (e.status.isSending && !prev.status.isSending) ||
        (e.status.isSending == prev.status.isSending && !e.originServerTs.isBefore(prev.originServerTs));
    if (newer) latest[e.senderId] = e;
  }
  final valid = p.answers.map((a) => a.$1).toSet();
  Set<String> pickedOf(Event e) {
    final r = e.content[pollResponse] ?? e.content['m.selections'];
    final list = r is Map ? r['answers'] : r;
    if (list is! List) return {};
    return list.whereType<String>().where(valid.contains).take(p.maxSelections).toSet();
  }

  final me = client.userID;
  // подсказка живёт, пока голос в пути; через 2 минуты верим ленте (например, проголосовали с другого устройства)
  final at = _myPickAt[start.eventId];
  if (at != null && DateTime.now().difference(at).inMinutes >= 2 && !(latest[me]?.status.isSending ?? false)) {
    _myPick.remove(start.eventId);
    _myPickAt.remove(start.eventId);
  }
  final over = _myPick[start.eventId];
  if (over != null && me != null) {
    final mineNow = latest[me];
    // сервер уже вернул ровно этот выбор — подсказка больше не нужна
    if (mineNow != null && !mineNow.status.isSending && setEquals(pickedOf(mineNow), over)) _myPick.remove(start.eventId);
  }
  for (final MapEntry(key: user, value: e) in latest.entries) {
    final picked = user == me && _myPick[start.eventId] != null ? _myPick[start.eventId]! : pickedOf(e);
    if (picked.isEmpty) continue;
    s.voters++;
    for (final a in picked) {
      s.counts[a] = (s.counts[a] ?? 0) + 1;
    }
    if (user == me) s.mine.addAll(picked);
  }
  // голосую впервые, а ответа ещё нет в ленте
  final first = _myPick[start.eventId];
  if (me != null && !latest.containsKey(me) && first != null && first.isNotEmpty) {
    s.voters++;
    for (final a in first) {
      s.counts[a] = (s.counts[a] ?? 0) + 1;
    }
    s.mine.addAll(first);
  }
  return s;
}

/// Когда опрос завершён (null — ещё идёт).
Event? pollStateOf(Event start, Timeline tl) {
  final p = PollData.of(start);
  return p == null ? null : pollState(start, tl, p).ended;
}

Future<void> endPoll(Room room, Event start) {
  ensureCanSend(room);
  return room.sendEvent({
      'm.relates_to': {'rel_type': 'm.reference', 'event_id': start.eventId},
      pollEnd: <String, Object?>{},
      'org.matrix.msc1767.text': 'Опрос завершён',
      'body': 'Опрос завершён',
    }, type: pollEnd);
}

String _until(DateTime t) {
  final now = DateTime.now();
  String two(int n) => n.toString().padLeft(2, '0');
  final hm = '${two(t.hour)}:${two(t.minute)}';
  if (t.year == now.year && t.month == now.month && t.day == now.day) return hm;
  return '${two(t.day)}.${two(t.month)} $hm';
}

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
      if (next.contains(id)) {
        next.remove(id);
      } else if (next.length < p.maxSelections) {
        next.add(id);
      } else {
        return; // больше вариантов выбрать нельзя
      }
    }
    await _send(context, next);
  }

  Future<void> _send(BuildContext context, Set<String> next) async {
    final before = _myPick[event.eventId];
    _myPick[event.eventId] = next; // сразу показываем новый выбор
    _myPickAt[event.eventId] = DateTime.now();
    pollChanged.value++;
    try {
      ensureCanSend(event.room);
      final sent = await event.room.sendEvent({
        'm.relates_to': {'rel_type': 'm.reference', 'event_id': event.eventId},
        pollResponse: {'answers': next.toList()},
        // стабильное название (Element и др.)
        'm.selections': next.toList(),
      }, type: pollResponse);
      if (sent == null) throw StateError('не отправлено'); // модуль Matrix сообщает об ошибке так, а не исключением
    } catch (_) {
      if (before == null) {
        _myPick.remove(event.eventId);
      } else {
        _myPick[event.eventId] = before;
      }
      pollChanged.value++;
      if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Голос не отправлен')));
    }
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<int>(valueListenable: pollChanged, builder: (context, _, __) => _build(context));

  Widget _build(BuildContext context) {
    final p = PollData.of(event);
    if (p == null) return const Text('Опрос');
    final s = pollState(event, timeline, p);
    final expired = p.endsAt != null && DateTime.now().isAfter(p.endsAt!);
    final ended = s.ended != null || expired;
    final showResults = ended || (p.disclosed && s.mine.isNotEmpty);
    final hint = Theme.of(context).hintColor;
    return ConstrainedBox(
      constraints: const BoxConstraints(minWidth: 240),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        Text(p.question, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16)),
        const SizedBox(height: 2),
        Text(
          '${ended ? 'Опрос завершён' : p.disclosed ? 'Опрос' : 'Итоги после завершения'}${p.maxSelections > 1 ? ' · несколько ответов' : ''}${!ended && p.endsAt != null ? ' · до ${_until(p.endsAt!)}' : ''}',
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
        Row(children: [
          Expanded(
            child: Text(
              s.voters == 0 ? 'Пока никто не проголосовал' : 'Проголосовали: ${s.voters}',
              style: TextStyle(fontSize: 12.5, color: hint),
            ),
          ),
          // как в Telegram: голос можно отменить и выбрать заново, пока опрос идёт
          if (!ended && s.mine.isNotEmpty)
            TextButton(
              style: TextButton.styleFrom(visualDensity: VisualDensity.compact, padding: const EdgeInsets.symmetric(horizontal: 8), foregroundColor: accent),
              onPressed: () => _send(context, {}),
              child: const Text('Отменить голос', style: TextStyle(fontSize: 12.5)),
            ),
        ]),
      ]),
    );
  }
}
