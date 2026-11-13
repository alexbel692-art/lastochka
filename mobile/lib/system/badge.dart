// Счётчик непрочитанных на компьютере (Windows), как в Telegram:
// • на кнопке Ласточки в панели задач — красный кружок с числом;
// • кнопка мигает, когда пришло новое сообщение, а окно не на переднем плане;
// • на значке в трее — такой же кружок, во всплывающей подсказке — число.
// Считаются сообщения в чатах со звуком, в заглушённых — только упоминания вас, плюс приглашения.
import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:ffi/ffi.dart';
import 'package:flutter/painting.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:matrix/matrix.dart';
import 'package:path/path.dart' as p;
import 'package:tray_manager/tray_manager.dart';

import '../main.dart' show client;

const _badgeMsg = 0x8000 + 0x0B42; // WM_APP + 0x0B42 — обрабатывает системная часть программы
const _red = Color(0xFFE5484D);

typedef _FindNative = IntPtr Function(Pointer<Utf16>, Pointer<Utf16>);
typedef _FindDart = int Function(Pointer<Utf16>, Pointer<Utf16>);
typedef _PostNative = Int32 Function(IntPtr, Uint32, IntPtr, IntPtr);
typedef _PostDart = int Function(int, int, int, int);

/// Сколько непрочитанных показать на значке.
int unreadForBadge(Iterable<Room> rooms) {
  var n = 0;
  for (final r in rooms) {
    if (r.membership == Membership.invite) {
      n++;
    } else if (r.membership == Membership.join) {
      final c = r.pushRuleState == PushRuleState.notify ? r.notificationCount : r.highlightCount;
      n += c;
    }
  }
  return n;
}

/// Текст на значке: до 99 — число, больше — «99+».
String badgeText(int n) => n <= 0 ? '' : (n > 99 ? '99+' : '$n');

class UnreadBadge {
  UnreadBadge._();
  static final instance = UnreadBadge._();

  StreamSubscription? _sub;
  Timer? _soon;
  int _last = -1;
  bool _busy = false;
  ui.Image? _trayBase;

  void start() {
    if (!Platform.isWindows || _sub != null) return;
    _sub = client.onSync.stream.listen((_) {
      _soon?.cancel();
      _soon = Timer(const Duration(milliseconds: 600), _update);
    });
    _update();
  }

  String get _dir => Platform.environment['TMP'] ?? Platform.environment['TEMP'] ?? Directory.systemTemp.path;

  Future<void> _update() async {
    if (_busy) {
      _soon?.cancel();
      _soon = Timer(const Duration(milliseconds: 600), _update);
      return;
    }
    final n = unreadForBadge(client.rooms);
    if (n == _last) return;
    final flash = _last >= 0 && n > _last;
    _last = n;
    _busy = true;
    try {
      final text = badgeText(n);
      if (n > 0) {
        // значок поверх кнопки в панели задач: 16, 24 и 32 точки — Windows выберет по масштабу экрана
        final overlay = <(int, Uint8List)>[for (final s in const [16, 24, 32]) (s, await _draw(s, text))];
        await File(p.join(_dir, 'lastochka_badge.ico')).writeAsBytes(icoFromPngs(overlay), flush: true);
        _trayBase ??= await _loadTray();
        final tray = <(int, Uint8List)>[for (final s in const [16, 24, 32]) (s, await _draw(s, text, base: _trayBase))];
        final trayPath = p.join(_dir, 'lastochka_tray_badge.ico');
        await File(trayPath).writeAsBytes(icoFromPngs(tray), flush: true);
        await trayManager.setIcon(trayPath);
        await trayManager.setToolTip('Ласточка — непрочитанных: $n');
      } else {
        await trayManager.setIcon('assets/tray.ico');
        await trayManager.setToolTip('Ласточка');
      }
      _post(n, flash);
    } catch (_) {
      // значок — удобство: ошибка рисования не должна мешать работе
    } finally {
      _busy = false;
    }
  }

  Future<ui.Image?> _loadTray() async {
    try {
      final data = await rootBundle.load('assets/tray.png');
      final codec = await ui.instantiateImageCodec(data.buffer.asUint8List());
      return (await codec.getNextFrame()).image;
    } catch (_) {
      return null;
    }
  }

  /// Красный кружок с числом; с [base] — значок Ласточки и кружок в правом нижнем углу.
  Future<Uint8List> _draw(int size, String text, {ui.Image? base}) async {
    final rec = ui.PictureRecorder();
    final c = Canvas(rec);
    final s = size.toDouble();
    if (base != null) {
      paintImage(canvas: c, rect: Rect.fromLTWH(0, 0, s, s), image: base, filterQuality: FilterQuality.high);
    }
    final d = base == null ? s : s * 0.66;
    final circle = Rect.fromLTWH(s - d, s - d, d, d);
    if (base != null) c.drawOval(circle.inflate(s * 0.04), Paint()..color = const Color(0xFFFFFFFF));
    c.drawOval(circle, Paint()..color = _red);
    final k = text.length >= 3 ? 0.44 : (text.length == 2 ? 0.58 : 0.72);
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(color: const Color(0xFFFFFFFF), fontSize: d * k, fontWeight: FontWeight.w700, fontFamily: 'Inter', height: 1),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(c, circle.center - Offset(tp.width / 2, tp.height / 2));
    final img = await rec.endRecording().toImage(size, size);
    final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
    img.dispose();
    return bytes!.buffer.asUint8List();
  }

  void _post(int n, bool flash) {
    final user32 = DynamicLibrary.open('user32.dll');
    final find = user32.lookupFunction<_FindNative, _FindDart>('FindWindowW');
    final post = user32.lookupFunction<_PostNative, _PostDart>('PostMessageW');
    final cls = 'FLUTTER_RUNNER_WIN32_WINDOW'.toNativeUtf16();
    final title = 'Ласточка'.toNativeUtf16();
    try {
      final hwnd = find(cls, title);
      if (hwnd != 0) post(hwnd, _badgeMsg, n, flash ? 1 : 0);
    } finally {
      calloc.free(cls);
      calloc.free(title);
    }
  }
}

/// Файл .ico из картинок PNG (так умеет Windows Vista и новее).
Uint8List icoFromPngs(List<(int, Uint8List)> images) {
  final b = BytesBuilder();
  final head = ByteData(6)
    ..setUint16(0, 0, Endian.little)
    ..setUint16(2, 1, Endian.little)
    ..setUint16(4, images.length, Endian.little);
  b.add(head.buffer.asUint8List());
  var offset = 6 + 16 * images.length;
  for (final (size, png) in images) {
    final e = ByteData(16)
      ..setUint8(0, size >= 256 ? 0 : size)
      ..setUint8(1, size >= 256 ? 0 : size)
      ..setUint16(4, 1, Endian.little)
      ..setUint16(6, 32, Endian.little)
      ..setUint32(8, png.length, Endian.little)
      ..setUint32(12, offset, Endian.little);
    b.add(e.buffer.asUint8List());
    offset += png.length;
  }
  for (final (_, png) in images) {
    b.add(png);
  }
  return b.toBytes();
}
