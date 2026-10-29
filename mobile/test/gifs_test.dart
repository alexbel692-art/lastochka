import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:lastochka/chat/gifs.dart';

void main() {
  test('ответ GIPHY: только https с серверов GIPHY', () {
    Map<String, Object?> im(String host) => {
          'fixed_width_small': {'url': 'https://$host/a/100w.gif'},
          'fixed_width_small_still': {'url': 'https://$host/a/100w_s.gif'},
          'fixed_height': {'url': 'https://$host/a/200.gif', 'width': '356', 'height': '200'},
        };
    final body = jsonEncode({
      'data': [
        {'id': 'ok', 'images': im('media1.giphy.com')},
        {'id': 'evil', 'images': im('evil.example')},
        {'id': 'broken'},
      ],
    });
    final r = parseGiphy(body);
    expect(r.map((g) => g.id).toList(), ['ok']);
    expect((r.first.w, r.first.h), (356, 200));
    expect(r.first.still.endsWith('_s.gif'), isTrue);
    expect(parseGiphy('{"data": 5}'), isEmpty);
  });

  test('размер GIF из заголовка; не-GIF — null', () {
    final gif = Uint8List.fromList(img.encodeGif(img.Image(width: 7, height: 3)));
    expect(gifSize(gif), (7, 3));
    expect(gifSize(Uint8List.fromList(img.encodePng(img.Image(width: 2, height: 2)))), isNull);
  });
}
