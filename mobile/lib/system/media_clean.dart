// Перед отправкой фото из него удаляются скрытые сведения: место съёмки (GPS), модель телефона,
// дата, имя автора и т. п. Фото поворачивается правильно и при необходимости уменьшается.
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

const maxPhotoSide = 2560;

class CleanImage {
  final Uint8List bytes;
  final String name;
  final int? width, height;
  CleanImage(this.bytes, this.name, this.width, this.height);
}

/// Очистить фото. Если формат не удалось разобрать — для JPEG вырезаем служебные блоки вручную.
Future<CleanImage> cleanPhoto(Uint8List bytes, String name) => compute(_clean, (bytes, name));

CleanImage _clean((Uint8List, String) a) {
  final (bytes, name) = a;
  final base = name.contains('.') ? name.substring(0, name.lastIndexOf('.')) : name;
  try {
    var im = img.decodeImage(bytes);
    if (im != null) {
      im = img.bakeOrientation(im); // поворот по EXIF «впекается» в само изображение
      if (im.width > maxPhotoSide || im.height > maxPhotoSide) {
        im = im.width >= im.height ? img.copyResize(im, width: maxPhotoSide) : img.copyResize(im, height: maxPhotoSide);
      }
      im.exif = img.ExifData(); // без GPS, модели, дат и прочего
      im.textData = null;
      final png = im.numChannels > 3 && name.toLowerCase().endsWith('.png');
      final out = png ? img.encodePng(im) : img.encodeJpg(im, quality: 88);
      return CleanImage(out, png ? '$base.png' : '$base.jpg', im.width, im.height);
    }
  } catch (_) {}
  return CleanImage(stripJpegMetadata(bytes), name, null, null);
}

/// Удалить из JPEG блоки APP1…APP15 (EXIF, XMP, IPTC) и комментарии, не перекодируя картинку.
Uint8List stripJpegMetadata(Uint8List b) {
  if (b.length < 4 || b[0] != 0xFF || b[1] != 0xD8) return b;
  final out = BytesBuilder(copy: false)..add([0xFF, 0xD8]);
  var i = 2;
  while (i + 4 <= b.length) {
    if (b[i] != 0xFF) return b; // повреждённый файл — не трогаем
    final m = b[i + 1];
    if (m == 0xDA) {
      out.add(Uint8List.sublistView(b, i)); // дальше — сами данные изображения
      return out.toBytes();
    }
    final len = (b[i + 2] << 8) | b[i + 3];
    if (len < 2 || i + 2 + len > b.length) return b;
    final drop = (m >= 0xE1 && m <= 0xEF) || m == 0xFE;
    if (!drop) out.add(Uint8List.sublistView(b, i, i + 2 + len));
    i += 2 + len;
  }
  return b;
}
