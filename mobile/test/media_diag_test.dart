import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lastochka/system/diag.dart';
import 'package:lastochka/system/media_clean.dart';

Uint8List box(String type, List<int> payload) {
  final size = 8 + payload.length;
  return Uint8List.fromList([(size >> 24) & 255, (size >> 16) & 255, (size >> 8) & 255, size & 255, ...type.codeUnits, ...payload]);
}

void main() {
  test('из видео удаляются место съёмки и даты, размер не меняется', () {
    final gps = '+55.7558+037.6173/'.codeUnits;
    final mvhd = box('mvhd', [0, 0, 0, 0, 1, 2, 3, 4, 5, 6, 7, 8, ...List.filled(88, 9)]);
    final udta = box('udta', box('©xyz', [0, 18, 0, 0, ...gps]));
    final moov = box('moov', [...mvhd, ...udta]);
    final file = Uint8List.fromList([...box('ftyp', 'isom'.codeUnits), ...moov, ...box('mdat', [1, 2, 3])]);
    final out = stripVideoMetadata(file)!;
    expect(out.length, file.length);
    expect(String.fromCharCodes(out), isNot(contains('+55.7558')));
    expect(String.fromCharCodes(out), contains('free'));
    // даты создания/изменения в mvhd обнулены
    final at = String.fromCharCodes(out).indexOf('mvhd') + 4;
    expect(out.sublist(at + 4, at + 12), List.filled(8, 0));
    // данные видео не тронуты
    expect(out.sublist(out.length - 3), [1, 2, 3]);
  });

  test('не видео — null', () {
    expect(stripVideoMetadata(Uint8List.fromList('hello world, not a video'.codeUnits)), isNull);
  });

  test('отчёт не выдаёт людей, сервер и адреса', () {
    final r = Diag.scrub('@anna:example.org в !abc123:example.org https://example.org/x 10.1.2.3 /Users/anna/app anna@mail.ru', host: 'example.org');
    expect(r, isNot(contains('anna')));
    expect(r, isNot(contains('example.org')));
    expect(r, isNot(contains('10.1.2.3')));
  });
}
