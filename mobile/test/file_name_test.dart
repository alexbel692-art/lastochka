// Имя файла в чате нельзя «перевернуть» невидимыми символами (подмена расширения).
import 'package:flutter_test/flutter_test.dart';
import 'package:lastochka/pages/chat_bubble.dart';

void main() {
  test('символы смены направления текста убираются', () {
    expect(cleanShownName('отчёт‮fdp.exe'), 'отчётfdp.exe');
    expect(cleanShownName('a⁦b⁩.txt'), 'ab.txt');
    expect(cleanShownName('​﻿'), 'Файл');
    expect(cleanShownName('фото.jpg'), 'фото.jpg');
  });
}
