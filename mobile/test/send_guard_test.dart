// Каждая отправка в чат (и звонок) должна проходить через ensureCanSend(...) — иначе при смене ключа
// собеседника сообщение ушло бы его новому (возможно, чужому) устройству. Тест читает исходники и находит
// обходы, в том числе вызовы, разбитые на несколько строк (`room\n    .sendTextEvent(`).
// Сама логика запрета проверяется функционально в trust_core_test.dart; кроме того, устройства со сменившимся
// ключом блокируются в модуле шифрования (Trust._enforce) — это второй, независимый от этого теста рубеж.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

final _send = RegExp(
    r'\.\s*(sendEvent|sendTextEvent|sendFileEvent|sendReaction|sendAgain|sendLocation|sendMessage|'
    r'sendToDevice|inviteToCall|answer|postReceipt|sendPoll)\s*\(');

List<String> scan(String path, String src) {
  final problems = <String>[];
  final lines = src.split('\n');
  final starts = <int>[0];
  for (var i = 0; i < src.length; i++) {
    if (src.codeUnitAt(i) == 10) starts.add(i + 1);
  }
  int lineOf(int off) {
    var lo = 0, hi = starts.length - 1;
    while (lo < hi) {
      final mid = (lo + hi + 1) >> 1;
      if (starts[mid] <= off) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    return lo;
  }

  for (final m in _send.allMatches(src)) {
    final ln = lineOf(m.start);
    final line = lines[ln].trimLeft();
    if (line.startsWith('//') || line.startsWith('///') || line.startsWith('*')) continue;
    if (m.group(1) == 'postReceipt') continue; // отметка о прочтении ключей не раздаёт
    // проверка — в той же строке или в 6 строках выше
    final before = lines.sublist(ln - 6 < 0 ? 0 : ln - 6, ln + 1).join('\n');
    if (!before.contains('ensureCanSend(')) problems.add('$path:${ln + 1}: ${lines[ln].trim()}');
  }
  return problems;
}

void main() {
  test('сканер находит и многострочные вызовы', () {
    expect(scan('x', 'void f() {\n  room\n      .sendTextEvent(t);\n}'), hasLength(1));
    expect(scan('x', 'void f() {\n  ensureCanSend(room);\n  room\n      .sendTextEvent(t);\n}'), isEmpty);
    expect(scan('x', 'void f() {\n  // room.sendTextEvent(t);\n}'), isEmpty);
    expect(scan('x', 'void f() => call.answer();'), hasLength(1));
  });

  test('все пути отправки и звонков проверяют смену ключа собеседника', () {
    final problems = <String>[];
    var found = 0;
    for (final f in Directory('lib').listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.dart'))) {
      final src = f.readAsStringSync();
      found += _send.allMatches(src).length;
      problems.addAll(scan(f.path, src));
    }
    expect(found, greaterThan(18), reason: 'тест не нашёл отправки — изменилась структура кода?');
    expect(problems, isEmpty, reason: 'отправка без ensureCanSend:\n${problems.join('\n')}');
  });
}
