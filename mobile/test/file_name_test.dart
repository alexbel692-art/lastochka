// Имя файла в чате нельзя «перевернуть» невидимыми символами (подмена расширения).
import 'package:flutter_test/flutter_test.dart';
import 'package:lastochka/pages/chat.dart';

void main() {
  test('символы смены направления текста убираются', () {
    expect(cleanShownName('отчёт\u202efdp.exe'), 'отчётfdp.exe');
    expect(cleanShownName('a\u2066b\u2069.txt'), 'ab.txt');
    expect(cleanShownName('\u200b\ufeff'), 'Файл');
    expect(cleanShownName('фото.jpg'), 'фото.jpg');
  });
}
