import 'package:flutter_test/flutter_test.dart';
import 'package:lastochka/system/lru.dart';

void main() {
  test('кэш ограничен и вытесняет давно не использованное', () {
    final c = Lru<int, String>(3);
    c[1] = 'a';
    c[2] = 'b';
    c[3] = 'c';
    expect(c[1], 'a'); // 1 стал свежим
    c[4] = 'd'; // вытесняется 2
    expect(c.length, 3);
    expect(c.containsKey(2), isFalse);
    expect(c.containsKey(1), isTrue);
    expect(c.putIfAbsent(5, () => 'e'), 'e');
    expect(c.containsKey(3), isFalse);
  });
}
