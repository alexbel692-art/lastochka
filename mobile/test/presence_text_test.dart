import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:lastochka/chat/presence_text.dart';

void main() {
  setUpAll(() => initializeDateFormatting('ru'));
  final now = DateTime(2026, 10, 29, 15, 0);
  String? t(Duration ago, {bool online = false, bool? active}) =>
      presenceText(online: online, currentlyActive: active, lastActive: now.subtract(ago), now: now);

  test('«в сети» и «был(а) … назад»', () {
    expect(t(Duration.zero, online: true), 'в сети');
    expect(t(const Duration(hours: 3), active: true), 'в сети');
    expect(t(const Duration(seconds: 20)), 'был(а) только что');
    expect(t(const Duration(minutes: 1)), 'был(а) 1 минуту назад');
    expect(t(const Duration(minutes: 3)), 'был(а) 3 минуты назад');
    expect(t(const Duration(minutes: 11)), 'был(а) 11 минут назад');
    expect(t(const Duration(minutes: 22)), 'был(а) 22 минуты назад');
    expect(t(const Duration(hours: 2)), 'был(а) сегодня в 13:00');
    expect(t(const Duration(hours: 20)), 'был(а) вчера в 19:00');
    expect(t(const Duration(days: 40)), startsWith('был(а) 19 сентября'));
    expect(presenceText(online: false, currentlyActive: null, lastActive: null, now: now), isNull);
  });
}
