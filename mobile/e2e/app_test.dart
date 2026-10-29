// Автотест интерфейса на эмуляторе Android с настоящим сервером Matrix (Synapse в сборке, tool/e2e_server.sh).
// Проходит как человек: вход → создание секретной фразы → приглашение в группу → чтение и отправка →
// крупные эмодзи → напоминание → панель стикеров и GIF → цвет оформления.
// Запуск: tool/e2e_android.sh (копирует файл в integration_test/ и запускает flutter test на эмуляторе).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:lastochka/main.dart' as app;
import 'package:lastochka/system/appearance.dart';

const server = String.fromEnvironment('E2E_SERVER', defaultValue: 'http://10.0.2.2:8008');
const user = String.fromEnvironment('E2E_USER', defaultValue: 'alice');
const pass = String.fromEnvironment('E2E_PASS');
const phrase = 'летит ласточка над тихим морем 2026';

/// Что видно на экране — в отчёт, если шаг не дождался.
String screenText() => find
    .byType(Text)
    .evaluate()
    .map((e) => (e.widget as Text).data ?? (e.widget as Text).textSpan?.toPlainText() ?? '')
    .where((s) => s.trim().isNotEmpty)
    .take(60)
    .join(' | ');

Future<void> settle(WidgetTester t, [int ms = 300]) async {
  await Future<void>.delayed(Duration(milliseconds: ms));
  await t.pump();
}

Future<void> waitFor(WidgetTester t, Finder f, String what, {int seconds = 60}) async {
  final end = DateTime.now().add(Duration(seconds: seconds));
  while (DateTime.now().isBefore(end)) {
    await settle(t, 250);
    if (f.evaluate().isNotEmpty) return;
  }
  throw TestFailure('не дождались за $seconds с: $what. На экране: ${screenText()}');
}

/// Ждать одно из нескольких состояний; возвращает номер найденного.
Future<int> waitAny(WidgetTester t, List<Finder> fs, String what, {int seconds = 60}) async {
  final end = DateTime.now().add(Duration(seconds: seconds));
  var last = DateTime.now();
  while (DateTime.now().isBefore(end)) {
    if (DateTime.now().difference(last).inSeconds >= 60) {
      last = DateTime.now();
      debugPrint('E2E: ждём «$what»… На экране: ${screenText()}');
    }
    await settle(t, 250);
    for (var i = 0; i < fs.length; i++) {
      if (fs[i].evaluate().isNotEmpty) return i;
    }
  }
  throw TestFailure('не дождались за $seconds с: $what. На экране: ${screenText()}');
}

/// Нажимать, пока не появится [expect] (нажатие могло прийти во время перестройки списка или под плашку).
Future<void> tapUntil(WidgetTester t, Finder target, Finder expect, String what, {int tries = 8}) async {
  for (var i = 0; i < tries; i++) {
    if (target.evaluate().isNotEmpty) {
      await t.ensureVisible(target.first);
      await settle(t);
      await t.tap(target.first, warnIfMissed: false);
    }
    for (var k = 0; k < 20; k++) {
      await settle(t, 250);
      if (expect.evaluate().isNotEmpty) return;
    }
  }
  throw TestFailure('нажатие не сработало: $what. На экране: ${screenText()}');
}

String currentStep = '';

Future<void> step(String name, Future<void> Function() body) async {
  currentStep = name;
  debugPrint('E2E: $name');
  await body();
  debugPrint('E2E: $name — готово');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Ласточка: вход, защита, чат, эмодзи, напоминание, стикеры, оформление', (t) async {
    expect(pass, isNotEmpty, reason: 'нужен --dart-define=E2E_PASS');
    // ошибки интерфейса (переполнение строк и т. п.) — собираем и показываем списком в конце
    final errs = <String>[];
    final prevOnError = FlutterError.onError;
    FlutterError.onError = (d) {
      final full = d.toString().split('\n');
      final i = full.indexWhere((l) => l.contains('relevant error-causing widget'));
      final where = i >= 0 && i + 1 < full.length ? full[i + 1].trim() : '';
      final line = '[$currentStep] ${d.exceptionAsString().split('\n').first} — $where';
      errs.add(line);
      debugPrint('E2E-ERR: $line');
    };
    try {
    app.main(const []);

    await step('экран входа', () async {
      await waitFor(t, find.text('Войти'), 'экран входа', seconds: 120);
      final fields = find.byType(TextField);
      await t.enterText(fields.at(0), server);
      await t.enterText(fields.at(1), user);
      await t.enterText(fields.at(2), pass);
      await t.testTextInput.receiveAction(TextInputAction.done);
    });

    await step('секретная фраза', () async {
      await waitFor(t, find.text('Сохранить фразу'), 'экран секретной фразы после входа', seconds: 180);
      final fields = find.byType(TextField);
      // экран может перерисоваться сразу после появления и стереть ввод — тогда вводим ещё раз
      for (var k = 0; k < 4; k++) {
        await t.pump(const Duration(seconds: 2));
        await t.enterText(fields.at(0), phrase);
        await t.enterText(fields.at(1), phrase);
        await t.pump(const Duration(milliseconds: 500));
        // Enter во втором поле — то же, что кнопка (кнопку на маленьком экране может закрыть всплывающая плашка)
        await t.testTextInput.receiveAction(TextInputAction.done);
        await t.pump(const Duration(seconds: 2));
        if (find.textContaining('слишком короткая').evaluate().isEmpty && find.textContaining('не совпадают').evaluate().isEmpty) break;
      }
      // сервер может попросить пароль (подтверждение действия) — тогда вводим
      // ключ из фразы считается нарочно долго (защита от подбора) — в отладочной сборке на эмуляторе это минуты
      final i = await waitAny(t, [find.text('Подтвердите паролем'), find.text('Тест-группа')], 'подтверждение паролем или список чатов', seconds: 900);
      if (i == 0) {
        await t.enterText(find.descendant(of: find.byType(AlertDialog), matching: find.byType(TextField)), pass);
        await t.tap(find.text('Подтвердить'));
      }
    });

    await step('приглашение в группу', () async {
      await waitFor(t, find.text('Тест-группа'), 'группа в списке чатов', seconds: 600);
      await tapUntil(t, find.ancestor(of: find.text('Тест-группа'), matching: find.byType(ListTile)), find.text('Вступить'), 'приглашение в группу');
      await t.tap(find.text('Вступить'));
      await waitFor(t, find.text('Привет из автотеста'), 'сообщение от второго участника', seconds: 90);
    });

    await step('отправка сообщения', () async {
      final composer = find.byType(TextField).last;
      await t.enterText(composer, 'Сообщение из автотеста');
      await settle(t);
      await t.tap(find.byIcon(Icons.send).last);
      await waitFor(
        t,
        find.byWidgetPredicate((w) => w is RichText && w.text.toPlainText().contains('Сообщение из автотеста')),
        'своё сообщение в ленте',
      );
    });

    await step('крупные эмодзи', () async {
      await t.enterText(find.byType(TextField).last, '👍');
      await settle(t);
      await t.tap(find.byIcon(Icons.send).last);
      await waitFor(t, find.byWidgetPredicate((w) => w is Text && w.data == '👍' && (w.style?.fontSize ?? 0) >= 40), 'крупный 👍 без пузыря');
    });

    await step('напоминание', () async {
      final msg = find.byWidgetPredicate((w) => w is RichText && w.text.toPlainText().contains('Привет из автотеста'));
      for (var i = 0; i < 5 && find.text('Напомнить').evaluate().isEmpty; i++) {
        await t.longPress(msg.first, warnIfMissed: false);
        await settle(t, 1000);
      }
      await waitFor(t, find.text('Напомнить'), 'меню сообщения');
      await t.tap(find.text('Напомнить'));
      await waitFor(t, find.text('Через час'), 'варианты напоминания');
      await t.tap(find.text('Через час'));
      await waitFor(t, find.byIcon(Icons.alarm_rounded), 'значок напоминания у сообщения');
    });

    await step('панель стикеров и GIF', () async {
      await t.tap(find.byTooltip('Эмодзи и стикеры'));
      await waitFor(t, find.text('Стикеры'), 'вкладки панели');
      await t.tap(find.text('Стикеры').last);
      await waitFor(t, find.text('Новый набор'), 'кнопка «Новый набор»');
      expect(find.text('GIF'), findsWidgets);
      await t.tap(find.byTooltip('Эмодзи и стикеры'));
      await settle(t);
    });

    await step('цвет оформления', () async {
      // системная кнопка «Назад» Android
      await t.binding.handlePopRoute();
      await settle(t, 600);
      await waitFor(t, find.text('Настройки'), 'нижнее меню');
      await t.tap(find.text('Настройки').last);
      await waitFor(t, find.text('Конфиденциальность'), 'настройки');
      final row = find.text('Тема, размер текста, обои чатов');
      await t.scrollUntilVisible(row, 300, scrollable: find.byType(Scrollable).first);
      await t.tap(row);
      await waitFor(t, find.byTooltip('Зелёный'), 'выбор цвета');
      await t.tap(find.byTooltip('Зелёный'));
      await settle(t, 600);
      expect(accents[Appearance.instance.accent.value].name, 'Зелёный');
    });
    } finally {
      FlutterError.onError = prevOnError;
    }
    if (errs.isNotEmpty) fail('ошибки интерфейса (${errs.length}): ${errs.toSet().take(8).join(' ‖ ')}');
  });
}
