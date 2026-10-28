import 'package:flutter_test/flutter_test.dart';
import 'package:lastochka/chat/emoji_only.dart';

void main() {
  test('крупные эмодзи: только сообщения из 1–3 эмодзи', () {
    expect(jumboEmojiCount('👍'), 1);
    expect(jumboEmojiCount(' 😂 '), 1);
    expect(jumboEmojiCount('❤️'), 1);
    expect(jumboEmojiCount('🔥🔥'), 2);
    expect(jumboEmojiCount('😀 😃 😄'), 3);
    expect(jumboEmojiCount('👍🏽'), 1); // с цветом кожи — одно
    expect(jumboEmojiCount('👨‍👩‍👧‍👦'), 1); // семья через склейку — одно
    expect(jumboEmojiCount('🇷🇺'), 1); // флаг
    expect(jumboEmojiCount('1️⃣'), 1);
    expect(jumboEmojiCount('😀😀😀😀'), isNull); // больше трёх — обычным текстом
    expect(jumboEmojiCount('ок 👍'), isNull);
    expect(jumboEmojiCount('5'), isNull);
    expect(jumboEmojiCount('©'), isNull); // знак без «как картинка» — текст
    expect(jumboEmojiCount('→'), isNull);
    expect(jumboEmojiCount(''), isNull);
    expect(jumboEmojiCount('   '), isNull);
  });
}
