// Каждый показ картинки из байтов (Image.memory / MemoryImage) должен декодировать её уменьшенной
// (cacheWidth / cacheHeight / ResizeImage) — иначе большая картинка распакуется в память целиком.
// Исключение — системные миниатюры галереи (они уже маленькие): помечены комментарием «миниатюра».
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('картинки из байтов показываются только уменьшенными', () {
    final call = RegExp(r'(Image\.memory|MemoryImage)\(');
    final problems = <String>[];
    var found = 0;
    for (final f in Directory('lib').listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.dart'))) {
      final src = f.readAsStringSync();
      for (final m in call.allMatches(src)) {
        found++;
        // аргументы вызова — до закрывающей скобки на том же уровне
        var depth = 0, i = m.end - 1, end = src.length;
        for (; i < src.length; i++) {
          if (src[i] == '(') depth++;
          if (src[i] == ')' && --depth == 0) {
            end = i;
            break;
          }
        }
        final args = src.substring(m.start, end);
        final line = src.substring(0, m.start).split('\n').length;
        final ctx = src.split('\n').sublist((line - 4).clamp(0, 1 << 30), line).join('\n');
        if (!RegExp(r'cacheWidth|cacheHeight|ResizeImage').hasMatch(args) && !ctx.contains('миниатюра')) {
          problems.add('${f.path}:$line');
        }
      }
    }
    expect(found, greaterThan(5));
    expect(problems, isEmpty, reason: 'картинка декодируется в полном размере:\n${problems.join('\n')}');
  });
}
