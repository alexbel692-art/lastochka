import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:lastochka/chat/formatting.dart';
import 'package:lastochka/system/lock.dart';
import 'package:lastochka/system/media_clean.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('оформление текста', () {
    test('без разметки — без formatted_body', () {
      expect(markdownToHtml('просто текст'), isNull);
      expect(textContent('привет')['formatted_body'], isNull);
    });
    test('жирный, курсив, код, ссылка', () {
      final h = markdownToHtml('**ж** __к__ ~~з~~ `a<b` https://example.org/x?y=1')!;
      expect(h, contains('<strong>ж</strong>'));
      expect(h, contains('<em>к</em>'));
      expect(h, contains('<del>з</del>'));
      expect(h, contains('<code>a&lt;b</code>'));
      expect(h, contains('<a href="https://example.org/x?y=1">'));
    });
    test('HTML из текста экранируется', () {
      final h = markdownToHtml('**<script>alert(1)</script>**')!;
      expect(h, isNot(contains('<script>')));
      expect(h, contains('&lt;script&gt;'));
    });
    test('упоминание', () {
      final c = textContent('Анна, привет', mentions: {'Анна': '@anna:example.org'});
      expect(c['formatted_body'], contains('https://matrix.to/#/@anna:example.org'));
      expect((c['m.mentions'] as Map)['user_ids'], ['@anna:example.org']);
    });
    test('подчёркивания внутри слов не трогаем', () {
      expect(markdownToHtml('file__name__x'), isNull);
    });
  });

  group('метаданные фото', () {
    test('EXIF удаляется при перекодировании', () async {
      final im = img.Image(width: 40, height: 30);
      im.exif.imageIfd['Make'] = img.IfdValueAscii('Phone');
      final jpg = img.encodeJpg(im);
      expect(img.decodeJpgExif(jpg)?.imageIfd['Make'], isNotNull);
      final clean = await cleanPhoto(jpg, 'IMG_1.jpg');
      final exif = img.decodeJpgExif(clean.bytes);
      expect(exif?.imageIfd['Make'], isNull);
      expect(clean.width, 40);
    });
    test('ручная очистка JPEG убирает APP1', () {
      // SOI, APP1 (EXIF), APP0, SOS
      final b = Uint8List.fromList([
        0xFF, 0xD8, //
        0xFF, 0xE1, 0x00, 0x06, 0x45, 0x78, 0x69, 0x66, //
        0xFF, 0xE0, 0x00, 0x04, 0x01, 0x02, //
        0xFF, 0xDA, 0x00, 0x02, 0x11, 0x22, 0xFF, 0xD9,
      ]);
      final out = stripJpegMetadata(b);
      expect(out, [0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x04, 0x01, 0x02, 0xFF, 0xDA, 0x00, 0x02, 0x11, 0x22, 0xFF, 0xD9]);
    });
    test('повреждённый файл не ломается', () {
      final b = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE1, 0xFF, 0xFF]);
      expect(stripJpegMetadata(b), b);
    });
  });

  group('код-пароль', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));
    test('паузы после ошибок, счётчик переживает перезапуск, экстренный код', () async {
      final lock = AppLock.instance;
      await lock.init();
      await lock.setPin('1234');
      expect(await lock.check('1234'), isTrue);
      for (var i = 0; i < 5; i++) {
        expect(await lock.check('0000'), isFalse);
      }
      expect(lock.fails, 5);
      expect(lock.blockedUntil!.isAfter(DateTime.now()), isTrue);
      // во время паузы даже верный код не принимается
      expect(await lock.check('1234'), isFalse);
      expect(await lock.setDuress('1234'), isFalse); // не может совпадать с обычным
      expect(await lock.setDuress('9999'), isTrue);
      var wiped = false;
      lock.onWipe = () async => wiped = true;
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('lock.blockedUntil');
      expect(await lock.check('9999'), isFalse);
      expect(wiped, isTrue);
    });
  });
}
