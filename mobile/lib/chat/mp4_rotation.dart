// Поворот видео из заголовка MP4/MOV — матрица дорожки (tkhd) видео.
// Телефоны пишут вертикальное видео «лёжа» и ставят в эту матрицу пометку «повернуть на 90°».
// mpv на сервере поворот не получает (см. mpv_video.dart), поэтому читаем его сами.
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

/// Поворот видео по часовой стрелке: 0, 90, 180 или 270. null — не MP4/MOV или видеодорожка не найдена.
Future<int?> mp4Rotation(String path) async {
  RandomAccessFile? f;
  try {
    f = await File(path).open();
    return await _Reader(f, await f.length()).rotation();
  } catch (_) {
    return null;
  } finally {
    await f?.close();
  }
}

/// Поворот по матрице tkhd (числа 16.16): по часовой = atan2(b, a), округлено до 90°.
int rotationFromMatrix(int a, int b) {
  if (a == 0 && b == 0) return 0;
  final deg = math.atan2(b.toDouble(), a.toDouble()) * 180 / math.pi;
  return (((deg / 90).round() * 90) % 360 + 360) % 360;
}

class _Reader {
  final RandomAccessFile f;
  final int length;
  int _reads = 0;
  _Reader(this.f, this.length);

  Future<Uint8List> _read(int pos, int n) async {
    if (++_reads > 4000) throw const FormatException('слишком много блоков');
    await f.setPosition(pos);
    final b = await f.read(n);
    if (b.length != n) throw const FormatException('файл оборван');
    return b;
  }

  /// Блоки (box) внутри [start, end): тип, начало содержимого, конец.
  Stream<(String, int, int)> _boxes(int start, int end) async* {
    var pos = start;
    while (pos + 8 <= end) {
      final h = ByteData.sublistView(await _read(pos, 8));
      var size = h.getUint32(0);
      final type = String.fromCharCodes(Uint8List.sublistView(h, 4, 8));
      var header = 8;
      if (size == 1) {
        if (pos + 16 > end) return;
        size = ByteData.sublistView(await _read(pos + 8, 8)).getUint64(0);
        header = 16;
      } else if (size == 0) {
        size = end - pos;
      }
      if (size < header || pos + size > end) return;
      yield (type, pos + header, pos + size);
      pos += size;
    }
  }

  Future<int?> rotation() async {
    // первый блок MP4/MOV — ftyp, wide, free, mdat или moov; иначе это не наш формат
    final first = String.fromCharCodes(await _read(4, 4));
    if (!const {'ftyp', 'moov', 'wide', 'free', 'mdat', 'skip', 'pnot'}.contains(first)) return null;
    await for (final (type, s, e) in _boxes(0, length)) {
      if (type != 'moov') continue;
      await for (final (t, ts, te) in _boxes(s, e)) {
        if (t != 'trak') continue;
        final r = await _trak(ts, te);
        if (r != null) return r;
      }
      return null;
    }
    return null;
  }

  /// Поворот видеодорожки; null — дорожка не видео.
  Future<int?> _trak(int s, int e) async {
    int? rot;
    var video = false;
    await for (final (t, bs, be) in _boxes(s, e)) {
      if (t == 'tkhd') {
        final version = (await _read(bs, 1))[0];
        final m = bs + (version == 1 ? 52 : 40); // версия и флаги, времена, номер дорожки, длительность, слой, громкость
        if (m + 8 > be) continue;
        final d = ByteData.sublistView(await _read(m, 8));
        rot = rotationFromMatrix(d.getInt32(0), d.getInt32(4));
      } else if (t == 'mdia') {
        await for (final (mt, ms, me) in _boxes(bs, be)) {
          if (mt == 'hdlr' && ms + 12 <= me) {
            video = String.fromCharCodes(await _read(ms + 8, 4)) == 'vide';
          }
        }
      }
    }
    return video ? (rot ?? 0) : null;
  }
}
