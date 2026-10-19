// Обои чата: цвет выбранной темы обоев и поверх — узор из мелких ласточек (как рисунки на фоне в Telegram).
// Рисуется векторно (чётко на любом экране) один раз и кэшируется отдельным слоем — прокрутке не мешает.
import 'dart:math';

import 'package:flutter/material.dart';

import '../system/appearance.dart';

class ChatWallpaper extends StatelessWidget {
  final Widget? child;
  final BorderRadius? radius;
  const ChatWallpaper({super.key, this.child, this.radius});

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<int>(
        valueListenable: Appearance.instance.wallpaper,
        builder: (context, i, _) {
          final w = wallpapers[i];
          final dark = Theme.of(context).brightness == Brightness.dark;
          final colors = dark ? w.dark : w.light;
          return DecoratedBox(
              decoration: BoxDecoration(borderRadius: radius, color: Color.lerp(colors.first, colors.last, 0.5)),
              child: child ?? const SizedBox.expand(),
            );
          }
          return DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: radius,
              gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: colors),
            ),
            child: Stack(fit: StackFit.passthrough, children: [
              // узор — под содержимым и ровно по его размеру
              if (w.pattern)
                Positioned.fill(child: RepaintBoundary(
                  child: ClipRRect(
                    borderRadius: radius ?? BorderRadius.zero,
                    child: CustomPaint(
                      // светлые обои — узор чуть темнее фона, тёмные — чуть светлее
                      painter: SwallowPattern(patternColor(w, dark)),
                    ),
                  ),
                )),
              child ?? const SizedBox.expand(),
            ]),
          );
        },
      );
}

/// Цвет узора для обоев.
Color patternColor(Wallpaper w, bool dark) {
  final colors = dark ? w.dark : w.light;
  return dark ? Colors.white.withValues(alpha: 0.055) : Color.lerp(colors[colors.length > 2 ? 2 : colors.length - 1], Colors.black, 0.35)!.withValues(alpha: 0.22);
}

/// Силуэт ласточки в квадрате 0…92 (летит вправо).
Path _swallow() {
  final p = Path()..moveTo(88, 44);
  p.quadraticBezierTo(82, 37, 74, 38);
  p.lineTo(64, 40);
  p.quadraticBezierTo(46, 20, 26, 4); // верхнее крыло
  p.quadraticBezierTo(44, 30, 54, 44);
  p.lineTo(42, 48);
  p.lineTo(4, 42); // раздвоенный хвост
  p.lineTo(34, 53);
  p.lineTo(10, 66);
  p.lineTo(44, 57);
  p.lineTo(56, 55);
  p.quadraticBezierTo(46, 72, 36, 90); // нижнее крыло
  p.quadraticBezierTo(58, 74, 68, 55);
  p.quadraticBezierTo(80, 53, 88, 44);
  return p..close();
}

final _bird = _swallow();

class SwallowPattern extends CustomPainter {
  final Color color;
  final double zoom; // меньше 1 — мельче (для миниатюр в настройках)
  SwallowPattern(this.color, {this.zoom = 1});

  // одна «плитка» 220×220: (x, y, масштаб, поворот в градусах)
  static const _tile = [
    (30.0, 30.0, 0.32, -15.0),
    (140.0, 20.0, 0.22, 20.0),
    (95.0, 95.0, 0.40, -30.0),
    (20.0, 150.0, 0.26, 10.0),
    (170.0, 130.0, 0.30, -5.0),
    (120.0, 185.0, 0.20, 35.0),
    (60.0, 205.0, 0.24, -20.0),
  ];
  static const _step = 220.0;

  @override
  void paint(Canvas canvas, Size size) {
    if (zoom != 1) {
      canvas.scale(zoom);
      size = size / zoom;
    }
    final paint = Paint()
      ..color = color
      ..isAntiAlias = true;
    final dot = Paint()..color = color.withValues(alpha: color.a * 0.8);
    for (var ty = -_step / 2; ty < size.height; ty += _step) {
      for (var tx = -_step / 2; tx < size.width; tx += _step) {
        for (final (x, y, sc, rot) in _tile) {
          canvas.save();
          canvas.translate(tx + x, ty + y);
          canvas.rotate(rot * pi / 180);
          canvas.scale(sc * 1.6);
          canvas.translate(-46, -46);
          canvas.drawPath(_bird, paint);
          canvas.restore();
        }
        // мелкие точки между птицами — «небо» не выглядит пустым
        canvas.drawCircle(Offset(tx + 75, ty + 160), 2.2, dot);
        canvas.drawCircle(Offset(tx + 190, ty + 70), 1.8, dot);
        canvas.drawCircle(Offset(tx + 160, ty + 200), 1.6, dot);
      }
    }
  }

  @override
  bool shouldRepaint(SwallowPattern old) => old.color != color || old.zoom != zoom;
}
