import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lastochka/chat/mp4_rotation.dart';

// Файлы сделаны ffmpeg с поворотом «как с телефона»; ожидаемый поворот — по часовой (как у mpv).
void main() {
  const dir = 'test/fixtures/rotation';
  test('поворот видео из заголовка MP4/MOV', () async {
    expect(await mp4Rotation('$dir/r0.mp4'), 0);
    expect(await mp4Rotation('$dir/cw90.mp4'), 90);
    expect(await mp4Rotation('$dir/cw180.mov'), 180);
    expect(await mp4Rotation('$dir/cw270_faststart.mp4'), 270);
    expect(await mp4Rotation('$dir/r0.mkv'), isNull); // не MP4 — поворот спросим у mpv
    expect(await mp4Rotation('$dir/нет-такого.mp4'), isNull);
  });

  test('оборванный и мусорный файл не роняют разбор', () async {
    final tmp = await Directory.systemTemp.createTemp('rot');
    try {
      final full = await File('$dir/cw90.mp4').readAsBytes();
      for (final n in [0, 3, 8, 30, full.length ~/ 2, full.length - 1]) {
        final f = File('${tmp.path}/cut$n.mp4');
        await f.writeAsBytes(full.sublist(0, n));
        final r = await mp4Rotation(f.path);
        expect(r == null || r == 90, isTrue, reason: 'обрезано до $n байт → $r');
      }
      final junk = File('${tmp.path}/junk.mp4');
      await junk.writeAsBytes(List.generate(4096, (i) => (i * 37 + 11) & 0xff));
      expect(await mp4Rotation(junk.path), isNull);
    } finally {
      await tmp.delete(recursive: true);
    }
  });

  test('матрица дорожки → поворот по часовой', () {
    const one = 0x10000;
    expect(rotationFromMatrix(one, 0), 0);
    expect(rotationFromMatrix(0, one), 90); // iPhone, вертикальное видео
    expect(rotationFromMatrix(-one, 0), 180);
    expect(rotationFromMatrix(0, -one), 270);
    expect(rotationFromMatrix(0, 0), 0);
  });
}
