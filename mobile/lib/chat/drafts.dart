// Черновики (у каждого чата свой) и отложенные сообщения. Хранятся зашифрованными на устройстве.
// Отложенные отправляются самой Ласточкой в назначенное время — пока она запущена
// (на Android — фоновой службой, на компьютере — в трее).
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:matrix/matrix.dart';

import '../main.dart';
import '../system/secure_store.dart';
import 'autodelete.dart';
import 'formatting.dart';

class Drafts {
  Drafts._();
  static final instance = Drafts._();

  final changed = ValueNotifier<int>(0);
  Map<String, String> _d = {};
  bool _loaded = false;
  Timer? _save;

  Future<void> init() async {
    final v = await SecureStore.instance.read('drafts');
    if (v is Map) _d = v.map((k, x) => MapEntry('$k', '$x'));
    _loaded = true;
    changed.value++;
  }

  String? of(String roomId) => _d[roomId];

  void set(String roomId, String text) {
    if (!_loaded) return;
    final t = text.trim().isEmpty ? null : text;
    if (_d[roomId] == t) return;
    t == null ? _d.remove(roomId) : _d[roomId] = t;
    changed.value++;
    _save?.cancel();
    _save = Timer(const Duration(milliseconds: 600), () => SecureStore.instance.write('drafts', _d).catchError((_) {}));
  }

  Future<void> clearAll() async {
    _d = {};
    await SecureStore.instance.write('drafts', null);
  }
}

class Scheduled {
  final String id, roomId, text;
  final DateTime at;
  final Map<String, String> mentions;
  Scheduled(this.id, this.roomId, this.text, this.at, this.mentions);

  Map<String, Object?> toJson() => {'id': id, 'room': roomId, 'text': text, 'at': at.millisecondsSinceEpoch, 'm': mentions};
  static Scheduled? fromJson(Object? j) {
    if (j is! Map) return null;
    final at = j['at'];
    if (j['room'] is! String || j['text'] is! String || at is! int) return null;
    final m = j['m'] is Map ? (j['m'] as Map).map((k, v) => MapEntry('$k', '$v')) : <String, String>{};
    return Scheduled('${j['id']}', j['room'] as String, j['text'] as String, DateTime.fromMillisecondsSinceEpoch(at), m);
  }
}

class Scheduler {
  Scheduler._();
  static final instance = Scheduler._();

  final items = ValueNotifier<List<Scheduled>>([]);
  Timer? _t;
  bool _busy = false;
  final Set<String> _inFlight = {};

  Future<void> init() async {
    final v = await SecureStore.instance.read('scheduled');
    if (v is List) items.value = v.map(Scheduled.fromJson).whereType<Scheduled>().toList();
    _t ??= Timer.periodic(const Duration(seconds: 15), (_) => _tick());
    unawaited(_tick());
  }

  List<Scheduled> forRoom(String roomId) => items.value.where((s) => s.roomId == roomId).toList()..sort((a, b) => a.at.compareTo(b.at));

  Future<void> _store() => SecureStore.instance.write('scheduled', items.value.map((s) => s.toJson()).toList());

  Future<void> add(Room room, String text, DateTime at, Map<String, String> mentions) async {
    items.value = [...items.value, Scheduled('${DateTime.now().microsecondsSinceEpoch}', room.id, text, at, mentions)];
    await _store();
  }

  Future<void> remove(String id) async {
    items.value = items.value.where((s) => s.id != id).toList();
    await _store();
  }

  Future<void> sendNow(String id) async {
    final s = items.value.where((x) => x.id == id).firstOrNull;
    if (s == null) return;
    await _send(s);
  }

  /// Отправить одно отложенное: не дважды и только если его не отменили.
  Future<void> _send(Scheduled s) async {
    if (!_inFlight.add(s.id)) return;
    try {
      if (!items.value.any((x) => x.id == s.id)) return; // отменено
      final room = client.getRoomById(s.roomId);
      if (room != null && room.membership == Membership.join) {
        final id = await room.sendEvent({...textContent(s.text, mentions: s.mentions), ...ttlExtra(room)});
        if (id == null) throw StateError('не отправлено');
      }
      await remove(s.id);
    } finally {
      _inFlight.remove(s.id);
    }
  }

  Future<void> _tick() async {
    if (_busy || !client.isLogged() || client.prevBatch == null) return;
    _busy = true;
    try {
      final due = items.value.where((s) => !s.at.isAfter(DateTime.now())).toList();
      for (final s in due) {
        try {
          await _send(s);
        } catch (_) {
          break; // нет сети — попробуем позже
        }
      }
    } finally {
      _busy = false;
    }
  }

  Future<void> clearAll() async {
    items.value = [];
    await SecureStore.instance.write('scheduled', null);
  }
}
