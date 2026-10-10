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
  final stripped = stripJpegMetadata(bytes);
  // не смогли ни перекодировать, ни аккуратно очистить — лучше не отправлять, чем отправить с GPS
  if (identical(stripped, bytes)) throw const FormatException('не удалось очистить фото');
  return CleanImage(stripped, name, null, null);
}

/// Удалить из JPEG блоки APP1…APP15 (EXIF, XMP, IPTC) и комментарии, не перекодируя картинку.
Uint8List stripJpegMetadata(Uint8List b) {
  if (b.length < 4 || b[0] != 0xFF || b[1] != 0xD8) return b;
  final out = BytesBuilder(copy: false)..add([0xFF, 0xD8]);
  var i = 2;
  while (i + 4 <= b.length) {
    if (b[i] != 0xFF) return b; // повреждённый файл — не трогаем
    if (b[i + 1] == 0xFF) {
      i++; // байты-заполнители между блоками
      continue;
    }
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

/// Видео MP4/MOV: место съёмки, модель телефона и прочие сведения лежат в блоках udta/meta/uuid(XMP),
/// даты — в mvhd/tkhd/mdhd. Блоки сведений превращаются в «пустые» (free) того же размера, даты
/// обнуляются — смещения внутри файла не меняются, видео играет как прежде.
/// null — это не MP4/MOV (такой файл не очищаем).
Future<Uint8List?> cleanVideo(Uint8List bytes) => compute(stripVideoMetadata, bytes);

Uint8List? stripVideoMetadata(Uint8List src) {
  if (src.length < 12) return null;
  final first = String.fromCharCodes(src.sublist(4, 8));
  if (!const {'ftyp', 'moov', 'mdat', 'free', 'wide', 'skip'}.contains(first)) return null;
  final b = Uint8List.fromList(src);
  final bd = ByteData.sublistView(b);
  var sawMoov = false;

  String type(int at) => String.fromCharCodes(b.sublist(at + 4, at + 8));
  void blank(int at, int size, int header) {
    b.setRange(at + 4, at + 8, 'free'.codeUnits);
    b.fillRange(at + header, at + size, 0);
  }

  void zeroTimes(int at, int header) {
    final p = at + header;
    if (p + 4 > b.length) return;
    final v = b[p];
    final n = v == 1 ? 16 : 8; // создание и изменение: 2×8 или 2×4 байта
    if (p + 4 + n <= b.length) b.fillRange(p + 4, p + 4 + n, 0);
  }

  bool walk(int start, int end, int depth) {
    var at = start;
    while (at + 8 <= end) {
      var size = bd.getUint32(at);
      var header = 8;
      if (size == 1) {
        if (at + 16 > end) return false;
        final big = bd.getUint64(at + 8);
        if (big > end - at) return false;
        size = big;
        header = 16;
      } else if (size == 0) {
        size = end - at;
      }
      if (size < header || at + size > end) return false;
      final t = type(at);
      switch (t) {
        case 'moov':
          sawMoov = true;
          if (!walk(at + header, at + size, depth + 1)) return false;
        case 'trak' || 'mdia':
          if (depth < 4 && !walk(at + header, at + size, depth + 1)) return false;
        case 'udta' || 'meta' || 'uuid' || 'Xtra':
          blank(at, size, header);
        case 'mvhd' || 'tkhd' || 'mdhd':
          zeroTimes(at, header);
      }
      at += size;
    }
    return true;
  }

  if (!walk(0, b.length, 0) || !sawMoov) return null;
  return b;
}
