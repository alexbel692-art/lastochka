import 'package:flutter_test/flutter_test.dart';
import 'package:lastochka/chat/album.dart';
import 'package:lastochka/system/lock.dart' show waitText;

void main() {
  test('ряды альбома покрывают все снимки и не длиннее трёх', () {
    for (var n = 1; n <= maxAlbum; n++) {
      final rows = albumRows(n);
      expect(rows.fold<int>(0, (a, b) => a + b), n, reason: 'n=$n');
      expect(rows.every((r) => r >= 1 && r <= 3), isTrue, reason: 'n=$n $rows');
    }
    expect(albumRows(3), [1, 2]);
    expect(albumRows(4), [2, 2]);
  });

  test('id альбома случайный', () {
    expect(newAlbumId(), isNot(newAlbumId()));
    expect(newAlbumId().length, 12);
  });

  test('текст ожидания', () {
    expect(waitText(const Duration(seconds: 29)), '30 с');
    expect(waitText(const Duration(seconds: 119)), '2 мин');
    expect(waitText(const Duration(seconds: 129)), '2 мин 10 с');
  });
}
