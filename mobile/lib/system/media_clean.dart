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
/// даты — в mvhd/tkhd/mdhd, а GPS «по кадрам» (GoPro, DJI, видеорегистраторы, некоторые телефоны) —
/// в отдельных дорожках метаданных/субтитров. Блоки сведений превращаются в «пустые» (free) того же
/// размера, даты обнуляются, данные таких дорожек затираются нулями — смещения внутри файла не меняются,
/// видео и звук играют как прежде. null — это не MP4/MOV (такой файл не очищаем).
Future<Uint8List?> cleanVideo(Uint8List bytes) => compute(stripVideoMetadata, bytes);

class _Trak {
  String? handler;
  int fixedSize = 0;
  List<int> sizes = [];
  List<(int, int)> stsc = []; // (первый кусок с 1, образцов в куске)
  List<int> chunks = [];
}

/// Работает прямо с переданным массивом (в отдельном потоке это уже копия).
Uint8List? stripVideoMetadata(Uint8List b) {
  if (b.length < 12) return null;
  final first = String.fromCharCodes(b.sublist(4, 8));
  if (!const {'ftyp', 'moov', 'mdat', 'free', 'wide', 'skip'}.contains(first)) return null;
  final bd = ByteData.sublistView(b);
  var sawMoov = false;
  final traks = <_Trak>[];
  _Trak? cur;

  String type(int at) => String.fromCharCodes(b.sublist(at + 4, at + 8));
  void blank(int at, int size, int header) {
    b.setRange(at + 4, at + 8, 'free'.codeUnits);
    b.fillRange(at + header, at + size, 0);
  }

  void zeroTimes(int p) {
    if (p + 4 > b.length) return;
    final n = b[p] == 1 ? 16 : 8; // создание и изменение: 2×8 или 2×4 байта
    if (p + 4 + n <= b.length) b.fillRange(p + 4, p + 4 + n, 0);
  }

  void table(String t, int p, int end) {
    final c = cur;
    if (c == null || p + 8 > end) return;
    switch (t) {
      case 'hdlr':
        if (p + 12 <= end) c.handler = String.fromCharCodes(b.sublist(p + 8, p + 12));
      case 'stsz':
        if (p + 12 > end) return;
        c.fixedSize = bd.getUint32(p + 4);
        final n = bd.getUint32(p + 8);
        if (c.fixedSize == 0 && p + 12 + n * 4 <= end) c.sizes = [for (var i = 0; i < n; i++) bd.getUint32(p + 12 + i * 4)];
        if (c.fixedSize != 0) c.sizes = List.filled(n.clamp(0, 10000000), c.fixedSize);
      case 'stsc':
        final n = bd.getUint32(p + 4);
        if (p + 8 + n * 12 <= end) c.stsc = [for (var i = 0; i < n; i++) (bd.getUint32(p + 8 + i * 12), bd.getUint32(p + 12 + i * 12))];
      case 'stco':
        final n = bd.getUint32(p + 4);
        if (p + 8 + n * 4 <= end) c.chunks = [for (var i = 0; i < n; i++) bd.getUint32(p + 8 + i * 4)];
      case 'co64':
        final n = bd.getUint32(p + 4);
        if (p + 8 + n * 8 <= end) c.chunks = [for (var i = 0; i < n; i++) bd.getUint64(p + 8 + i * 8)];
    }
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
        case 'trak':
          if (depth > 6) break;
          final prev = cur;
          cur = _Trak();
          traks.add(cur!);
          final ok = walk(at + header, at + size, depth + 1);
          cur = prev;
          if (!ok) return false;
        case 'mdia' || 'minf' || 'stbl':
          if (depth < 6 && !walk(at + header, at + size, depth + 1)) return false;
        case 'udta' || 'meta' || 'uuid' || 'Xtra':
          blank(at, size, header);
        case 'mvhd' || 'tkhd' || 'mdhd':
          zeroTimes(at + header);
        case 'hdlr' || 'stsz' || 'stsc' || 'stco' || 'co64':
          table(t, at + header, at + size);
      }
      at += size;
    }
    return true;
  }

  if (!walk(0, b.length, 0) || !sawMoov) return null;

  // дорожки метаданных и субтитров (там бывают координаты по кадрам) — затираем их данные
  for (final t in traks) {
    if (!const {'meta', 'text', 'sbtl', 'subt', 'gpmd', 'camm'}.contains(t.handler)) continue;
    var sample = 0;
    for (var ci = 0; ci < t.chunks.length; ci++) {
      var perChunk = 0;
      for (final (firstChunk, n) in t.stsc) {
        if (firstChunk <= ci + 1) perChunk = n;
      }
      var off = t.chunks[ci];
      for (var k = 0; k < perChunk && sample < t.sizes.length; k++, sample++) {
        final sz = t.sizes[sample];
        if (off < 0 || off + sz > b.length) return null; // таблицы не сходятся — лучше не отправлять
        b.fillRange(off, off + sz, 0);
        off += sz;
      }
    }
  }
  return b;
}
