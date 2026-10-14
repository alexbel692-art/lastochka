// «Trojan Source» (CVE-2021-42574): невидимые символы смены направления текста в исходниках позволяют
// показать код не таким, каким его видит компилятор. В коде Ласточки их быть не должно — только
// записью \u202e и т. п. (символы для эмодзи — U+200D, U+FE0F — разрешены).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('в исходниках нет символов смены направления текста', () {
    final bad = RegExp('[\u202a-\u202e\u2066-\u2069\u200e\u200f\u061c]');
    final found = <String>[];
    for (final dir in ['lib', 'test', 'tool', 'packages']) {
      final d = Directory(dir);
      if (!d.existsSync()) continue;
      for (final f in d.listSync(recursive: true).whereType<File>()) {
        if (!RegExp(r'\.(dart|kt|swift|cpp|h|py|iss|yaml|sh)$').hasMatch(f.path)) continue;
        String s;
        try {
          s = f.readAsStringSync();
        } catch (_) {
          continue;
        }
        final lines = s.split('\n');
        for (var i = 0; i < lines.length; i++) {
          if (bad.hasMatch(lines[i])) found.add('${f.path}:${i + 1}');
        }
      }
    }
    expect(found, isEmpty, reason: 'замените символ записью \\u…');
  });
}
