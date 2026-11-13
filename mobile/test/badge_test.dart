import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lastochka/system/badge.dart';

void main() {
  test('текст значка', () {
    expect(badgeText(0), '');
    expect(badgeText(7), '7');
    expect(badgeText(99), '99');
    expect(badgeText(150), '99+');
  });

  test('ico из png: заголовок и смещения', () {
    final a = Uint8List.fromList([1, 2, 3]), b = Uint8List.fromList([4, 5]);
    final ico = icoFromPngs([(16, a), (32, b)]);
    final d = ByteData.sublistView(ico);
    expect(d.getUint16(2, Endian.little), 1);
    expect(d.getUint16(4, Endian.little), 2);
    expect(ico[6], 16);
    expect(d.getUint32(6 + 8, Endian.little), 3);
    expect(d.getUint32(6 + 12, Endian.little), 6 + 32);
    expect(d.getUint32(22 + 12, Endian.little), 6 + 32 + 3);
    expect(ico.sublist(38), [1, 2, 3, 4, 5]);
  });
}
