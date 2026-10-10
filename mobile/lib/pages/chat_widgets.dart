part of 'chat.dart';

// Мелкие виджеты ленты и общие функции.
String _plural(int n, String one, String few, String many) {
  final m10 = n % 10, m100 = n % 100;
  if (m10 == 1 && m100 != 11) return one;
  if (m10 >= 2 && m10 <= 4 && (m100 < 12 || m100 > 14)) return few;
  return many;
}

/// Короткое описание сообщения (для ответа, закрепа, списка чатов).
String eventPreview(Event e, Timeline? tl) {
  final d = tl == null ? e : e.getDisplayEvent(tl);
  if (d.redacted) return 'Сообщение удалено';
  if (d.type == EventTypes.Encrypted) return '🔒 Зашифрованное сообщение';
  if (d.type == EventTypes.Sticker) return 'Стикер';
  if (isPollStart(d)) return pollPreview(d);
  if (isRound(d)) return '⏺ Видеосообщение';
  return switch (d.messageType) {
    MessageTypes.Image => '🖼 Фото',
    MessageTypes.Video => '🎬 Видео',
    'm.key.verification.request' => '🔐 Запрос подтверждения',
    MessageTypes.Audio => d.content.containsKey('org.matrix.msc3245.voice') ? '🎤 Голосовое сообщение' : '🎵 ${d.body}',
    MessageTypes.File => '📎 ${d.body}',
    _ => stripMarkdown(d.calcUnlocalizedBody(hideReply: true)).replaceAll('\n', ' '),
  };
}

class _SwipeToReply extends StatefulWidget {
  final Widget child;
  final VoidCallback onReply;
  const _SwipeToReply({required this.child, required this.onReply});
  @override
  State<_SwipeToReply> createState() => _SwipeToReplyState();
}

class _SwipeToReplyState extends State<_SwipeToReply> {
  double _dx = 0;
  bool _armed = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onHorizontalDragUpdate: (d) {
        final nx = (_dx + d.delta.dx).clamp(-80.0, 0.0);
        final armed = nx < -56;
        if (armed && !_armed) HapticFeedback.selectionClick();
        setState(() {
          _dx = nx;
          _armed = armed;
        });
      },
      onHorizontalDragEnd: (_) {
        if (_armed) widget.onReply();
        setState(() {
          _dx = 0;
          _armed = false;
        });
      },
      child: Stack(alignment: Alignment.centerRight, children: [
        if (_dx < 0)
          Positioned(
            right: 8,
            child: Opacity(
              opacity: (-_dx / 56).clamp(0.0, 1.0),
              child: CircleAvatar(radius: 16, backgroundColor: Colors.black26, child: Icon(Icons.reply, size: 18, color: Colors.white.withValues(alpha: 0.9))),
            ),
          ),
        AnimatedContainer(
          duration: Duration(milliseconds: _dx == 0 ? 180 : 0),
          transform: Matrix4.translationValues(_dx, 0, 0),
          child: widget.child,
        ),
      ]),
    );
  }
}

class _Blink extends StatefulWidget {
  const _Blink();
  @override
  State<_Blink> createState() => _BlinkState();
}

class _BlinkState extends State<_Blink> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 700))..repeat(reverse: true);
  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FadeTransition(
        opacity: _c,
        child: Container(width: 10, height: 10, decoration: const BoxDecoration(color: Colors.redAccent, shape: BoxShape.circle)),
      );
}

class _DayChip extends StatelessWidget {
  final DateTime d;
  const _DayChip(this.d);
  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final s = DateUtils.isSameDay(d, now)
        ? 'Сегодня'
        : DateUtils.isSameDay(d, now.subtract(const Duration(days: 1)))
            ? 'Вчера'
            : DateFormat(d.year == now.year ? 'd MMMM' : 'd MMMM y', 'ru').format(d);
    return _ServiceChip(s);
  }
}

class _ServiceChip extends StatelessWidget {
  final String text;
  const _ServiceChip(this.text);
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Center(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.22), borderRadius: BorderRadius.circular(12)),
            child: Text(text, style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w500)),
          ),
        ),
      );
}

/// Ширина области чата: на планшете чат занимает только правую часть экрана.
class _PaneWidth extends InheritedWidget {
  final double width;
  const _PaneWidth({required this.width, required super.child});
  @override
  bool updateShouldNotify(_PaneWidth old) => old.width != width;
}

double paneWidth(BuildContext context) =>
    context.dependOnInheritedWidgetOfExactType<_PaneWidth>()?.width ?? MediaQuery.sizeOf(context).width;
