import 'package:flutter/material.dart';

/// Форма пузыря как в Telegram: скруглённый, у последнего сообщения в группе — «хвостик» снизу.
class TgBubbleBorder extends ShapeBorder {
  final bool mine, tail;
  static const double tailW = 7, r = 17, rs = 5;
  const TgBubbleBorder({required this.mine, required this.tail});

  @override
  EdgeInsetsGeometry get dimensions => EdgeInsets.only(left: mine ? 0 : tailW, right: mine ? tailW : 0);

  @override
  Path getInnerPath(Rect rect, {TextDirection? textDirection}) => getOuterPath(rect, textDirection: textDirection);

  @override
  Path getOuterPath(Rect rect, {TextDirection? textDirection}) {
    final body = Rect.fromLTRB(rect.left + (mine ? 0 : tailW), rect.top, rect.right - (mine ? tailW : 0), rect.bottom);
    // со стороны собеседника углы в середине группы чуть острее — как в Telegram
    final near = tail ? 0.0 : rs;
    final rr = RRect.fromRectAndCorners(
      body,
      topLeft: Radius.circular(mine ? r : rs),
      topRight: Radius.circular(mine ? rs : r),
      bottomLeft: Radius.circular(mine ? r : near),
      bottomRight: Radius.circular(mine ? near : r),
    );
    final path = Path()..addRRect(rr);
    if (!tail) return path;
    final t = Path();
    if (mine) {
      t
        ..moveTo(body.right - 1, body.bottom - 16)
        ..quadraticBezierTo(body.right, body.bottom - 2, rect.right, body.bottom)
        ..quadraticBezierTo(body.right - 6, body.bottom + 0.5, body.right - 12, body.bottom)
        ..close();
    } else {
      t
        ..moveTo(body.left + 1, body.bottom - 16)
        ..quadraticBezierTo(body.left, body.bottom - 2, rect.left, body.bottom)
        ..quadraticBezierTo(body.left + 6, body.bottom + 0.5, body.left + 12, body.bottom)
        ..close();
    }
    return Path.combine(PathOperation.union, path, t);
  }

  @override
  void paint(Canvas canvas, Rect rect, {TextDirection? textDirection}) {}

  @override
  ShapeBorder scale(double t) => this;
}
