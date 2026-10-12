// Оценка секретной фразы: насколько её трудно подобрать. Считается грубая «энтропия»
// (длина × разнообразие символов) после вычёркивания известных слабых кусков:
// последовательностей клавиш и цифр, годов, повторов, популярных слов и вашего логина.
import 'dart:math';

import 'package:flutter/material.dart';

enum Strength { weak, fair, strong }

const _weakWords = [
  'пароль', 'password', 'passw0rd', 'ласточка', 'lastochka', 'matrix', 'element', 'qwerty', 'йцукен', 'asdf', 'фыва', 'zxcv', 'ячсм',
  'admin', 'админ', 'привет', 'privet', 'люблю', 'iloveyou', 'секрет', 'secret', 'фраза', 'phrase', 'москва', 'moscow', 'russia', 'россия',
  'qazwsx', 'abc', 'абв', 'test', 'тест', 'user', 'login', 'логин', 'welcome', 'letmein', 'monkey', 'dragon', 'football', 'футбол',
];
const _rows = ['qwertyuiop', 'asdfghjkl', 'zxcvbnm', 'йцукенгшщзхъ', 'фывапролджэ', 'ячсмитьбю', '1234567890', 'abcdefghijklmnopqrstuvwxyz', 'абвгдеёжзийклмнопрстуфхцчшщъыьэюя'];

/// Битов «стойкости» (ориентир: меньше 40 — слабо, 40–60 — средне, больше 60 — надёжно).
double phraseBits(String phrase, {String? login}) {
  var s = phrase.toLowerCase();
  if (login != null && login.length >= 3) s = s.replaceAll(login.toLowerCase(), '§');
  for (final w in _weakWords) {
    s = s.replaceAll(w, '§');
  }
  // года и даты
  s = s.replaceAll(RegExp(r'(19|20)\d\d'), '§');
  // отрезки клавиатурных рядов и алфавита длиной от 3 (в обе стороны)
  for (final row in _rows) {
    for (final r in [row, row.split('').reversed.join()]) {
      for (var len = r.length; len >= 3; len--) {
        for (var i = 0; i + len <= r.length; i++) {
          s = s.replaceAll(r.substring(i, i + len), '§');
        }
      }
    }
  }
  // повторы одного символа и повторяющиеся куски: «aaaa», «абабаб»
  s = s.replaceAllMapped(RegExp(r'(.)\1{2,}'), (m) => m[1]!);
  s = s.replaceAllMapped(RegExp(r'(.{2,}?)\1+'), (m) => m[1]!);
  var pool = 0;
  final orig = phrase;
  if (RegExp(r'[a-z]').hasMatch(orig)) pool += 26;
  if (RegExp(r'[A-Z]').hasMatch(orig)) pool += 26;
  if (RegExp(r'[а-яё]').hasMatch(orig)) pool += 33;
  if (RegExp(r'[А-ЯЁ]').hasMatch(orig)) pool += 33;
  if (RegExp(r'\d').hasMatch(orig)) pool += 10;
  if (RegExp(r'[^a-zA-Zа-яА-ЯёЁ\d]').hasMatch(orig)) pool += 20;
  if (pool == 0) return 0;
  final unique = s.split('').toSet().length;
  // мало разных символов — подбирается быстро, сколько бы их ни было
  final effLen = min(s.length, unique * 3);
  return effLen * log(pool) / ln2;
}

Strength phraseStrength(String phrase, {String? login}) {
  final b = phraseBits(phrase, login: login);
  return b < 40 ? Strength.weak : b < 60 ? Strength.fair : Strength.strong;
}

/// Полоска надёжности под полем ввода фразы.
class PhraseMeter extends StatelessWidget {
  final TextEditingController controller;
  final String? login;
  const PhraseMeter({super.key, required this.controller, this.login});

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<TextEditingValue>(
        valueListenable: controller,
        builder: (_, v, __) {
          final t = v.text.trim();
          if (t.isEmpty) return const SizedBox(height: 4);
          final st = t.length < 12 ? Strength.weak : phraseStrength(t, login: login);
          final (color, label, frac) = switch (st) {
            Strength.weak => (Colors.redAccent, t.length < 12 ? 'Короткая — нужно от 12 символов' : 'Слабая — легко подобрать', 0.25),
            Strength.fair => (Colors.orange, 'Средняя — добавьте ещё слово', 0.6),
            Strength.strong => (Colors.green, 'Надёжная', 1.0),
          };
          return Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Row(children: [
              Expanded(child: ClipRRect(borderRadius: BorderRadius.circular(3), child: LinearProgressIndicator(value: frac, minHeight: 5, color: color, backgroundColor: color.withValues(alpha: 0.15)))),
              const SizedBox(width: 10),
              Text(label, style: TextStyle(color: color, fontSize: 12.5, fontWeight: FontWeight.w500)),
            ]),
          );
        },
      );
}
