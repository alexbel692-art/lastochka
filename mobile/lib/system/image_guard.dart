// Защита от «картинок-бомб»: файл в несколько килобайт может описывать картинку 30000×30000 точек,
// и её распаковка съедает гигабайты памяти. Размеры читаются из заголовка, без распаковки.
import 'dart:typed_data';
import 'dart:ui' as ui;

/// Не больше ~52 мегапикселей (фото с 50-Мп камер проходят) и не длиннее 16384 точек по стороне.
/// В память картинка целиком не распаковывается: КАЖДЫЙ показ (лента, просмотр, аватар, галерея) декодирует
/// её сразу уменьшенной (cacheWidth, не больше 4096 точек по ширине) — пиковая память ≈ 64 МБ на картинку.
/// Тест image_guard_test следит, чтобы ни один показ картинки не обходился без уменьшения.
const _maxPixels = 52 * 1000 * 1000;
const _maxSide = 16384;

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
