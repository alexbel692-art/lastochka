import 'package:flutter_test/flutter_test.dart';
import 'package:lastochka/system/file_safety.dart';

void main() {
  test('точки и пробелы в конце не прячут программу', () {
    expect(isDangerousFile('счёт.exe.'), isTrue);
    expect(isDangerousFile('счёт.exe. .'), isTrue);
    expect(isDangerousFile('справка.chm'), isTrue);
    expect(isDangerousFile('отчёт.pdf'), isFalse);
    expect(safeFileName('счёт.exe. '), 'счёт.exe');
    expect(safeFileName('CON.txt'), '_CON.txt');
  });
}
