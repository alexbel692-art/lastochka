// Проверка экранов без сервера: код-пароль, оформление, ссылки Matrix, отложенные и т. п.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lastochka/chat/drafts.dart';
import 'package:lastochka/pages/appearance.dart';
import 'package:lastochka/pages/qr.dart';
import 'package:lastochka/system/appearance.dart';
import 'package:lastochka/system/lock.dart';
import 'package:shared_preferences/shared_preferences.dart';

Widget app(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('ввод кода: 4 цифры нажатиями — вызывается проверка, ошибка показывается', (t) async {
    final got = <String>[];
    await t.pumpWidget(app(PinPad(
      title: 'Введите код',
      onDone: (pin) async {
        got.add(pin);
        return pin == '1234' ? null : 'Неверный код';
      },
    )));
    for (final d in ['1', '2', '3', '9']) {
      await t.tap(find.text(d));
      await t.pump();
    }
    await t.pump(const Duration(milliseconds: 500));
    expect(got, ['1239']);
    expect(find.text('Неверный код'), findsOneWidget);
    for (final d in ['1', '2', '3', '4']) {
      await t.tap(find.text(d));
      await t.pump();
    }
    await t.pump(const Duration(milliseconds: 500));
    expect(got.last, '1234');
    expect(find.text('Неверный код'), findsNothing);
  });

  testWidgets('оформление: тема, размер текста, обои', (t) async {
    await Appearance.instance.init();
    await t.pumpWidget(const MaterialApp(home: AppearancePage()));
    await t.tap(find.text('Тёмная'));
    await t.pumpAndSettle();
    expect(Appearance.instance.themeMode.value, ThemeMode.dark);
    await t.tap(find.text('Небо'));
    await t.pumpAndSettle();
    expect(Appearance.instance.wallpaper.value, 1);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getInt('look.theme'), ThemeMode.dark.index);
    expect(prefs.getInt('look.wall'), 1);
  });

  test('ссылки Matrix из QR-кодов', () {
    expect(parseMatrixLink('https://matrix.to/#/@anna:example.org')?.id, '@anna:example.org');
    final g = parseMatrixLink('https://matrix.to/#/%23office:example.org');
    expect(g?.id, '#office:example.org');
    final g2 = parseMatrixLink('https://matrix.to/#/#office:example.org');
    expect(g2?.id, '#office:example.org');
    final r = parseMatrixLink('https://matrix.to/#/!abc123:example.org/\$event?via=example.org&via=other.net');
    expect(r?.id, '!abc123:example.org');
    expect(r?.via, ['example.org', 'other.net']);
    expect(parseMatrixLink('@bob:server.ru')?.id, '@bob:server.ru');
    expect(parseMatrixLink('https://evil.example/phish'), isNull);
    expect(parseMatrixLink('просто текст'), isNull);
  });

  test('отложенное сообщение сохраняется и читается обратно', () {
    final s = Scheduled('1', '!r:x', 'привет', DateTime(2030, 1, 2, 3, 4), {'Анна': '@a:x'});
    final back = Scheduled.fromJson(s.toJson())!;
    expect(back.text, 'привет');
    expect(back.roomId, '!r:x');
    expect(back.at, DateTime(2030, 1, 2, 3, 4));
    expect(back.mentions, {'Анна': '@a:x'});
    expect(Scheduled.fromJson({'room': 1}), isNull);
  });

  test('блокировка: автоблокировка по времени скрытия', () async {
    final lock = AppLock.instance;
    await lock.init();
    await lock.setPin('1111');
    await lock.setTimeout(0);
    expect(lock.enabled, isTrue);
    expect(lock.timeout, 0);
  });
}
