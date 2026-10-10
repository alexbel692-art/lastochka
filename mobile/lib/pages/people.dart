// Выбор людей с сервера: для нового чата (один человек) и для группы / приглашений (несколько, галочками).
// Список собирается из справочника сервера и участников ваших чатов, поиск — по имени и логину.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart';

import '../main.dart';
import '../widgets/avatar.dart';

class Person {
  final String id;
  final String name;
  final Uri? avatar;
  const Person(this.id, this.name, this.avatar);
}

/// Пункт над списком (например, «Новая группа»). Нажатие закрывает выбор и возвращает [value].
class PickerAction {
  final IconData icon;
  final String label, value;
  const PickerAction(this.icon, this.label, this.value);
}

class PickResult {
  final List<String> ids;
  final String? action;
  const PickResult(this.ids, [this.action]);
}

/// [multi] — галочки и кнопка «Готово»; иначе нажатие на человека сразу выбирает его.
Future<PickResult?> pickPeople(
  BuildContext context, {
  required String title,
  bool multi = true,
  String doneLabel = 'Готово',
  Set<String> exclude = const {},
  List<PickerAction> actions = const [],
  bool allowEmpty = false,
}) =>
    Navigator.of(context).push<PickResult>(MaterialPageRoute(
      builder: (_) => _PeoplePage(title: title, multi: multi, doneLabel: doneLabel, exclude: exclude, actions: actions, allowEmpty: allowEmpty),
    ));

// служебные пользователи мостов и ботов (по соглашению их логины начинаются с «_» или имени моста)
final _service = RegExp(r'^@(_|(telegram|whatsapp|signal|discord|slack|facebook|instagram)_)');

class _PeoplePage extends StatefulWidget {
  final String title, doneLabel;
  final bool multi, allowEmpty;
  final Set<String> exclude;
  final List<PickerAction> actions;
  const _PeoplePage({required this.title, required this.multi, required this.doneLabel, required this.exclude, required this.actions, required this.allowEmpty});
  @override
  State<_PeoplePage> createState() => _PeoplePageState();
}

class _PeoplePageState extends State<_PeoplePage> {
  final _q = TextEditingController();
  final Map<String, Person> _all = {};
  final List<String> _picked = [];
  bool _loading = true;
  Timer? _debounce;
  String get _domain => client.userID?.domain ?? '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _q.dispose();
    super.dispose();
  }

  void _add(String id, String? name, Uri? avatar) {
    if (id == client.userID || widget.exclude.contains(id) || _service.hasMatch(id)) return;
    final n = (name == null || name.trim().isEmpty) ? id.substring(1).split(':').first : name.trim();
    final old = _all[id];
    if (old == null || (old.avatar == null && avatar != null) || old.name == id.substring(1).split(':').first) _all[id] = Person(id, n, avatar ?? old?.avatar);
  }

  Future<List<Profile>> _dir(String term) async {
    try {
      return (await client.searchUserDirectory(term, limit: 500)).results;
    } catch (_) {
      return const [];
    }
  }

  Future<void> _load() async {
    // участники ваших чатов — видны всегда
    for (final r in client.rooms) {
      for (final u in r.getParticipants()) {
        if (u.membership == Membership.join || u.membership == Membership.invite) _add(u.id, u.displayName, u.avatarUrl);
      }
    }
    if (mounted) setState(() {});
    // справочник сервера: пустой запрос и запрос по имени сервера дают всех, кого сервер разрешает видеть
    final terms = {'', _domain.split('.').first, _domain};
    final res = await Future.wait(terms.map(_dir));
    for (final list in res) {
      for (final p in list) {
        _add(p.userId, p.displayName, p.avatarUrl);
      }
    }
    if (mounted) setState(() => _loading = false);
  }

  void _search(String q) {
    setState(() {});
    _debounce?.cancel();
    q = q.trim();
    if (q.isEmpty) return;
    _debounce = Timer(const Duration(milliseconds: 350), () async {
      final r = await _dir(q);
      if (!mounted) return;
      setState(() {
        for (final p in r) {
          _add(p.userId, p.displayName, p.avatarUrl);
        }
      });
    });
  }

  List<Person> get _visible {
    final q = _q.text.trim().toLowerCase();
    final list = _all.values.where((p) => q.isEmpty || p.name.toLowerCase().contains(q) || p.id.toLowerCase().contains(q)).toList();
    // сначала люди с вашего сервера, внутри — по имени
    list.sort((a, b) {
      final la = a.id.endsWith(':$_domain') ? 0 : 1, lb = b.id.endsWith(':$_domain') ? 0 : 1;
      return la != lb ? la - lb : a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return list;
  }

  /// Набранный логин, которого нет в списке, — можно добавить вручную.
  String? get _typedId {
    var s = _q.text.trim();
    if (s.isEmpty || s.contains(' ')) return null;
    if (!s.startsWith('@')) s = '@$s';
    if (!s.contains(':')) s = '$s:$_domain';
    if (!RegExp(r'^@[a-z0-9._=\-/+]+:[A-Za-z0-9.\-:]+$').hasMatch(s)) return null;
    if (_all.containsKey(s) || s == client.userID || widget.exclude.contains(s)) return null;
    return s;
  }

  void _tap(Person p) {
    if (!widget.multi) return Navigator.pop(context, PickResult([p.id]));
    setState(() => _picked.contains(p.id) ? _picked.remove(p.id) : _picked.add(p.id));
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final accent = t.colorScheme.primary;
    final hint = t.hintColor;
    final people = _visible;
    final typed = _typedId;
    final showActions = widget.actions.isNotEmpty && _q.text.trim().isEmpty;
    return Scaffold(
      appBar: AppBar(
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(widget.title),
          if (widget.multi) Text(_picked.isEmpty ? 'Отметьте людей' : 'Выбрано: ${_picked.length}', style: TextStyle(fontSize: 13, color: hint, fontWeight: FontWeight.w400)),
        ]),
      ),
      floatingActionButton: widget.multi && (_picked.isNotEmpty || widget.allowEmpty)
          ? FloatingActionButton.extended(
              onPressed: () => Navigator.pop(context, PickResult(List.of(_picked))),
              icon: const Icon(Icons.arrow_forward_rounded),
              label: Text(widget.doneLabel),
            )
          : null,
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 6),
          child: TextField(
            controller: _q,
            enableIMEPersonalizedLearning: false,
            autocorrect: false,
            onChanged: _search,
            decoration: InputDecoration(
              hintText: 'Поиск по имени или логину',
              prefixIcon: const Icon(Icons.search),
              filled: true,
              isDense: true,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
              suffixIcon: _q.text.isEmpty ? null : IconButton(icon: const Icon(Icons.close), onPressed: () => setState(_q.clear)),
            ),
          ),
        ),
        // выбранные — лентой сверху, как в Telegram; нажатие убирает
        AnimatedSize(
          duration: const Duration(milliseconds: 200),
          child: _picked.isEmpty
              ? const SizedBox(width: double.infinity)
              : SizedBox(
                  height: 84,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    children: [
                      for (final id in _picked)
                        InkWell(
                          borderRadius: BorderRadius.circular(12),
                          onTap: () => setState(() => _picked.remove(id)),
                          child: SizedBox(
                            width: 68,
                            child: Column(children: [
                              const SizedBox(height: 4),
                              Stack(clipBehavior: Clip.none, children: [
                                Avatar(mxc: _all[id]?.avatar, name: _all[id]?.name ?? id, size: 48),
                                Positioned(
                                  right: -2,
                                  bottom: -2,
                                  child: Container(
                                    decoration: BoxDecoration(color: t.scaffoldBackgroundColor, shape: BoxShape.circle),
                                    padding: const EdgeInsets.all(2),
                                    child: CircleAvatar(radius: 8, backgroundColor: hint, child: const Icon(Icons.close, size: 11, color: Colors.white)),
                                  ),
                                ),
                              ]),
                              const SizedBox(height: 4),
                              Text((_all[id]?.name ?? id).split(' ').first, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12)),
                            ]),
                          ),
                        ),
                    ],
                  ),
                ),
        ),
        Expanded(
          child: ListView(padding: const EdgeInsets.only(bottom: 96), children: [
            if (showActions) ...[
              for (final a in widget.actions)
                ListTile(
                  leading: CircleAvatar(radius: 22, backgroundColor: accent.withValues(alpha: 0.12), child: Icon(a.icon, color: accent)),
                  title: Text(a.label, style: TextStyle(color: accent, fontWeight: FontWeight.w500)),
                  onTap: () => Navigator.pop(context, PickResult(const [], a.value)),
                ),
              const Divider(height: 8),
            ],
            if (typed != null)
              ListTile(
                leading: CircleAvatar(radius: 22, backgroundColor: accent.withValues(alpha: 0.12), child: Icon(Icons.person_add_alt_1_outlined, color: accent)),
                title: Text(typed),
                subtitle: const Text('Добавить по логину'),
                onTap: () {
                  _all[typed] = Person(typed, typed.substring(1).split(':').first, null);
                  _tap(_all[typed]!);
                  if (widget.multi) _q.clear();
                },
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: Row(children: [
                Text(_q.text.trim().isEmpty ? 'Пользователи' : 'Найдено', style: TextStyle(color: accent, fontWeight: FontWeight.w600, fontSize: 13.5)),
                if (_loading) ...[const SizedBox(width: 8), const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2))],
              ]),
            ),
            for (final p in people) _row(p, accent, hint),
            if (!_loading && people.isEmpty && typed == null)
              Padding(
                padding: const EdgeInsets.all(24),
                child: Text(_q.text.trim().isEmpty ? 'Пока никого нет — начните вводить имя или логин' : 'Никого не нашлось', textAlign: TextAlign.center, style: TextStyle(color: hint)),
              ),
          ]),
        ),
      ]),
    );
  }

  Widget _row(Person p, Color accent, Color hint) {
    final on = _picked.contains(p.id);
    final login = p.id.endsWith(':$_domain') ? p.id.substring(1).split(':').first : p.id;
    return ListTile(
      onTap: () => _tap(p),
      leading: Avatar(mxc: p.avatar, name: p.name, size: 46),
      title: Text(p.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w500)),
      subtitle: Text(login, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: hint, fontSize: 13)),
      trailing: !widget.multi
          ? null
          : AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              width: 24,
              height: 24,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: on ? accent : Colors.transparent,
                border: Border.all(color: on ? accent : hint.withValues(alpha: 0.6), width: 2),
              ),
              child: on ? const Icon(Icons.check, size: 16, color: Colors.white) : null,
            ),
    );
  }
}
