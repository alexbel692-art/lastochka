// Защита от «картинок-бомб»: файл в несколько килобайт может описывать картинку 30000×30000 точек,
// и её распаковка съедает гигабайты памяти. Размеры читаются из заголовка, без распаковки.
import 'dart:typed_data';
import 'dart:ui' as ui;

/// Не больше ~40 мегапикселей и не длиннее 20000 точек по одной стороне.
const _maxPixels = 40 * 1000 * 1000;
const _maxSide = 20000;

/// Те же байты, если картинку безопасно показывать; null — слишком большая или повреждённая.
Future<Uint8List?> guardImage(Uint8List? bytes) async {
  if (bytes == null || bytes.isEmpty) return null;
  ui.ImmutableBuffer? buf;
  ui.ImageDescriptor? d;
  try {
    buf = await ui.ImmutableBuffer.fromUint8List(bytes);
    d = await ui.ImageDescriptor.encoded(buf);
    final w = d.width, h = d.height;
    if (w <= 0 || h <= 0 || w > _maxSide || h > _maxSide || w * h > _maxPixels) return null;
    return bytes;
  } catch (_) {
    return null;
  } finally {
    d?.dispose();
    buf?.dispose();
  }
}
