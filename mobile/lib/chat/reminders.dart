// Напоминания о сообщениях: «Напомнить» в меню сообщения — через час, вечером, завтра в 9:00 или в
// выбранное время. В срок приходит уведомление, нажатие открывает чат на этом сообщении.
//
// Список хранится на устройстве в зашифрованном хранилище (там и короткий текст сообщения для
// уведомления) — серверу и другим устройствам он не виден. На телефоне и Mac напоминание ставит
// сама система — придёт и при закрытой Ласточке; на Windows Ласточка работает в трее и показывает его сама
// (если в срок компьютер был выключен — покажет при следующем запуске).
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:matrix/matrix.dart';

import '../system/notify.dart';
import '../system/secure_store.dart';

class Reminder {
  final String roomId, eventId, roomName, preview;
  final int at; // мс с 1970
  const Reminder(this.roomId, this.eventId, this.at, this.roomName, this.preview);

  int get notifyId => 50000 + (eventId.hashCode & 0xFFFFF);
  DateTime get time => DateTime.fromMillisecondsSinceEpoch(at);

  Map<String, Object?> toJson() => {'r': roomId, 'e': eventId, 't': at, 'n': roomName, 'p': preview};
  static Reminder? fromJson(Object? j) {
    if (j is! Map) return null;
    final r = j['r'], e = j['e'], t = j['t'];
    if (r is! String || e is! String || t is! int) return null;
    return Reminder(r, e, t, '${j['n'] ?? ''}', '${j['p'] ?? ''}');
  }
}

class Reminders {
  Reminders._();
  static final instance = Reminders._();

  /// Список изменился — пузыри перерисовывают значок будильника.
  final changed = ValueNotifier<int>(0);
  List<Reminder> _items = [];
  Timer? _tick;
  bool get _byOs => Platform.isAndroid || Platform.isIOS || Platform.isMacOS;

  Reminder? of(String eventId) => _items.where((r) => r.eventId == eventId).firstOrNull;

  Future<void> init() async {
    try {
      final raw = await SecureStore.instance.read('reminders');
      if (raw is List) _items = raw.map(Reminder.fromJson).whereType<Reminder>().toList();
    } catch (e) {
      Logs().w('[Ласточка] напоминания не прочитаны', e);
    }
    if (_byOs) {
      // уже пришедшие от системы — убрать из списка
      final now = DateTime.now().millisecondsSinceEpoch;
      final before = _items.length;
      _items.removeWhere((r) => r.at <= now);
      if (_items.length != before) await _save();
    } else {
      _tick ??= Timer.periodic(const Duration(seconds: 20), (_) => _fireDue());
      await _fireDue();
    }
    changed.value++;
  }

  Future<void> _save() async {
    _items.sort((a, b) => a.at.compareTo(b.at));
    await SecureStore.instance.write('reminders', [for (final r in _items) r.toJson()]);
    changed.value++;
  }

  /// Компьютер: показать наступившие (и пропущенные, пока компьютер был выключен).
  Future<void> _fireDue() async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final due = _items.where((r) => r.at <= now).toList();
    if (due.isEmpty) return;
    _items.removeWhere((r) => r.at <= now);
    await _save();
    for (final r in due) {
      await showReminderNotification(r.notifyId, r.roomId, r.eventId, r.roomName, r.preview);
    }
  }

  /// Поставить (или переставить) напоминание о сообщении. false — система не дала поставить.
  Future<bool> set(Room room, Event e, DateTime at, String preview) async {
    await cancel(e.eventId, save: false);
    final short = preview.length > 120 ? '${preview.substring(0, 120)}…' : preview;
    final r = Reminder(room.id, e.eventId, at.millisecondsSinceEpoch, room.getLocalizedDisplayname(), short);
    if (_byOs && !await scheduleReminderNotification(r.notifyId, at, r.roomId, r.eventId, r.roomName, r.preview)) {
      await _save();
      return false;
    }
    _items.add(r);
    await _save();
    return true;
  }

  Future<void> cancel(String eventId, {bool save = true}) async {
    final old = of(eventId);
    if (old == null) return;
    _items.removeWhere((r) => r.eventId == eventId);
    if (_byOs) await cancelReminderNotification(old.notifyId);
    if (save) await _save();
  }
}

/// Варианты «Напомнить» относительно [now], как в Telegram: (подпись, время).
List<(String, DateTime)> reminderChoices(DateTime now) {
  DateTime at(DateTime d, int h) => DateTime(d.year, d.month, d.day, h);
  final tomorrow = now.add(const Duration(days: 1));
  final out = <(String, DateTime)>[
    ('Через 20 минут', now.add(const Duration(minutes: 20))),
    ('Через час', now.add(const Duration(hours: 1))),
    ('Через 3 часа', now.add(const Duration(hours: 3))),
    if (now.hour < 18) ('Сегодня в 19:00', at(now, 19)),
    ('Завтра в 9:00', at(tomorrow, 9)),
  ];
  // понедельник утром — если завтра не понедельник
  if (tomorrow.weekday != DateTime.monday) {
    final days = (DateTime.monday - now.weekday + 7) % 7;
    out.add(('В понедельник в 9:00', at(now.add(Duration(days: days == 0 ? 7 : days)), 9)));
  }
  return out;
}
