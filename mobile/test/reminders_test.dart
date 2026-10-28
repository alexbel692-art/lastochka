import 'package:flutter_test/flutter_test.dart';
import 'package:lastochka/chat/reminders.dart';

void main() {
  test('варианты «Напомнить»', () {
    // четверг, 15:00
    final thu = DateTime(2026, 10, 29, 15, 0);
    final c = {for (final (l, t) in reminderChoices(thu)) l: t};
    expect(c['Через час'], DateTime(2026, 10, 29, 16, 0));
    expect(c['Сегодня в 19:00'], DateTime(2026, 10, 29, 19));
    expect(c['Завтра в 9:00'], DateTime(2026, 10, 30, 9));
    expect(c['В понедельник в 9:00'], DateTime(2026, 11, 2, 9));
    for (final t in c.values) {
      expect(t.isAfter(thu), isTrue);
    }
    // вечером «сегодня в 19:00» нет; в воскресенье «понедельник» — это «завтра»
    final sunEvening = DateTime(2026, 11, 1, 20, 0);
    final c2 = {for (final (l, t) in reminderChoices(sunEvening)) l: t};
    expect(c2.containsKey('Сегодня в 19:00'), isFalse);
    expect(c2.containsKey('В понедельник в 9:00'), isFalse);
    expect(c2['Завтра в 9:00'], DateTime(2026, 11, 2, 9));
    // в понедельник днём — следующий понедельник
    final mon = DateTime(2026, 11, 2, 12);
    final c3 = {for (final (l, t) in reminderChoices(mon)) l: t};
    expect(c3['В понедельник в 9:00'], DateTime(2026, 11, 9, 9));
  });

  test('напоминание: запись и чтение', () {
    const r = Reminder('!a:s', r'$e', 1700000000000, 'Чат', 'текст');
    final back = Reminder.fromJson(r.toJson())!;
    expect((back.roomId, back.eventId, back.at, back.roomName, back.preview), ('!a:s', r'$e', 1700000000000, 'Чат', 'текст'));
    expect(Reminder.fromJson({'r': 1}), isNull);
  });
}
