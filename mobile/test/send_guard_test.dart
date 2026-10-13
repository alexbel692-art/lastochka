// Каждая отправка в чат должна проходить через ensureCanSend(...) — иначе при смене ключа собеседника
// сообщение ушло бы его новому (возможно, чужому) устройству. Тест читает исходники и находит обходы.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('все пути отправки проверяют смену ключа собеседника', () {
    final send = RegExp(r'\.(sendEvent|sendTextEvent|sendFileEvent|sendReaction|sendAgain|sendLocation)\(');
    final problems = <String>[];
    var found = 0;
    for (final f in Directory('lib').listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.dart'))) {
      final lines = f.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final l = lines[i].trimLeft();
        if (l.startsWith('//') || !send.hasMatch(l)) continue;
        found++;
        // проверка — в той же строке или в 4 строках выше
        final before = lines.sublist(i - 4 < 0 ? 0 : i - 4, i + 1).join('\n');
        if (!before.contains('ensureCanSend(')) problems.add('${f.path}:${i + 1}: ${lines[i].trim()}');
      }
    }
    expect(found, greaterThan(15), reason: 'тест не нашёл отправки — изменилась структура кода?');
    expect(problems, isEmpty, reason: 'отправка без ensureCanSend:\n${problems.join('\n')}');
  });
}
