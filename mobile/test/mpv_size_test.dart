import 'package:flutter_test/flutter_test.dart';
import 'package:lastochka/chat/mpv_video.dart' show fitSize;

void main() {
  test('размер картинки mpv: никогда не ноль, пропорции сохранены, стороны чётные', () {
    // вертикальное видео с телефона — у media_kit ширина получалась 0
    expect(fitSize(1080, 1920, 1280, 720), (w: 404, h: 720));
    expect(fitSize(1920, 1080, 1280, 720), (w: 1280, h: 720));
    expect(fitSize(640, 360, 1280, 720), (w: 640, h: 360));
    expect(fitSize(null, null, 1280, 720), (w: 1280, h: 720));
    expect(fitSize(0, 100, 1280, 720), (w: 1280, h: 720));
    expect(fitSize(1, 5000, 1280, 720), (w: 2, h: 720));
    for (final (w, h) in [(1080, 1920), (720, 1280), (1080, 1350), (3840, 2160), (2160, 3840), (101, 99), (3, 7)]) {
      final s = fitSize(w, h, 1280, 720);
      expect(s.w >= 2 && s.h >= 2 && s.w.isEven && s.h.isEven && s.w <= 1280 && s.h <= 720, isTrue, reason: '$w×$h → $s');
    }
  });
}
