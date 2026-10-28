// Сообщение только из эмодзи (1–3 штуки) показывается крупно и без пузыря, как в Telegram.
import 'package:flutter/widgets.dart' show StringCharacters;

/// Сколько эмодзи в тексте, если он состоит только из них (1–3); иначе null.
int? jumboEmojiCount(String text) {
  final t = text.trim();
  if (t.isEmpty || t.length > 64) return null;
  var n = 0;
  for (final g in t.characters) {
    if (g.trim().isEmpty) continue; // пробелы между эмодзи
    if (!_isEmoji(g)) return null;
    if (++n > 3) return null;
  }
  return n == 0 ? null : n;
}

/// Размер шрифта крупных эмодзи: одно — крупнее, три — меньше.
double jumboEmojiSize(int n) => switch (n) { 1 => 48, 2 => 40, _ => 34 };

bool _isEmoji(String g) {
  final runes = g.runes.toList();
  var pictographic = false;
  final vs16 = runes.contains(0xFE0F);
  // клавиши: 1️⃣ #️⃣ *️⃣
  if (runes.length >= 2 && runes.last == 0x20E3 && _keycapBase(runes.first)) return true;
  // флаги стран: две «региональные буквы»
  if (runes.length == 2 && runes.every((r) => r >= 0x1F1E6 && r <= 0x1F1FF)) return true;
  for (final r in runes) {
    if (r == 0x200D || r == 0xFE0F || r == 0x20E3) continue; // склейка, «как картинка», рамка клавиши
    if (r >= 0x1F3FB && r <= 0x1F3FF) continue; // цвет кожи
    if (r >= 0xE0020 && r <= 0xE007F) continue; // флаги регионов (теги)
    if (_pictographic(r)) {
      // ©, ®, ™ и стрелки — эмодзи, только если явно указано «как картинка»
      if (r < 0x2300 && !vs16) return false;
      pictographic = true;
      continue;
    }
    return false;
  }
  return pictographic;
}

bool _keycapBase(int r) => (r >= 0x30 && r <= 0x39) || r == 0x23 || r == 0x2A;

bool _pictographic(int r) =>
    r == 0x00A9 ||
    r == 0x00AE ||
    r == 0x203C ||
    r == 0x2049 ||
    r == 0x2122 ||
    r == 0x2139 ||
    (r >= 0x2194 && r <= 0x2199) ||
    (r >= 0x21A9 && r <= 0x21AA) ||
    (r >= 0x231A && r <= 0x231B) ||
    r == 0x2328 ||
    r == 0x23CF ||
    (r >= 0x23E9 && r <= 0x23F3) ||
    (r >= 0x23F8 && r <= 0x23FA) ||
    r == 0x24C2 ||
    (r >= 0x25AA && r <= 0x25AB) ||
    r == 0x25B6 ||
    r == 0x25C0 ||
    (r >= 0x25FB && r <= 0x25FE) ||
    (r >= 0x2600 && r <= 0x27BF) ||
    (r >= 0x2934 && r <= 0x2935) ||
    (r >= 0x2B05 && r <= 0x2B07) ||
    (r >= 0x2B1B && r <= 0x2B1C) ||
    r == 0x2B50 ||
    r == 0x2B55 ||
    r == 0x3030 ||
    r == 0x303D ||
    r == 0x3297 ||
    r == 0x3299 ||
    (r >= 0x1F000 && r <= 0x1FAFF);
