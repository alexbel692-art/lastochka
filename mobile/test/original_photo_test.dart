import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:lastochka/system/media_clean.dart';

void main() {
  test('фото в оригинале: без GPS, но с поворотом; PNG без текстовых блоков', () {
    final src = img.Image(width: 8, height: 4);
    src.exif.imageIfd.orientation = 6;
    src.exif.imageIfd['Make'] = img.IfdValueAscii('PhoneMaker');
    final jpg = img.encodeJpg(src);
    expect(String.fromCharCodes(jpg).contains('PhoneMaker'), isTrue);

    final out = cleanOriginalSync(jpg)!;
    final exif = img.decodeJpgExif(out);
    expect(exif?.imageIfd.orientation, 6); // поворот сохранён
    expect(exif?.gpsIfd.isEmpty ?? true, isTrue); // места съёмки нет
    expect(String.fromCharCodes(out).contains('PhoneMaker'), isFalse); // прочих сведений тоже
    expect(img.decodeJpg(out)!.width, 8); // картинка та же, не перекодирована

    final png = img.encodePng(img.Image(width: 3, height: 3));
    final withText = _addPngText(png, 'Location', 'secret');
    expect(String.fromCharCodes(withText).contains('secret'), isTrue);
    final cleanPng = cleanOriginalSync(withText)!;
    expect(String.fromCharCodes(cleanPng).contains('secret'), isFalse);
    expect(img.decodePng(cleanPng)!.width, 3);

    expect(cleanOriginalSync(Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8, 9, 10])), isNull); // не JPEG/PNG
  });
}

/// PNG с текстовым блоком tEXt перед IEND.
Uint8List _addPngText(Uint8List png, String key, String value) {
  final data = [...key.codeUnits, 0, ...value.codeUnits];
  final chunk = BytesBuilder()
    ..add((ByteData(4)..setUint32(0, data.length)).buffer.asUint8List())
    ..add('tEXt'.codeUnits)
    ..add(data)
    ..add([0, 0, 0, 0]); // контрольная сумма — разбору здесь не важна
  final iend = png.length - 12;
  return (BytesBuilder()..add(png.sublist(0, iend))..add(chunk.toBytes())..add(png.sublist(iend))).toBytes();
}
