import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:lastochka/chat/sticker_packs.dart';

void main() {
  test('опись набора: только mxc, не больше 200, имена без «переворота» текста', () {
    final images = {
      for (var i = 0; i < 250; i++) 's$i': {'url': 'mxc://srv/m$i', 'body': 'Стикер $i'},
      'bad': {'url': 'https://evil/x.png'},
      'emote': {'url': 'mxc://srv/e', 'usage': ['emoticon']},
    };
    final j = utf8.encode(jsonEncode({'type': 'app.lastochka.sticker_pack', 'name': 'Коты\u202Egnp.exe', 'images': images}));
    final (name, items) = parsePackManifest(Uint8List.fromList(j))!;
    expect(name.contains('\u202E'), isFalse);
    expect(items.length, maxPackItems);
    expect(items.every((i) => i.url.scheme == 'mxc'), isTrue);
    expect(parsePackManifest(Uint8List.fromList(utf8.encode('{"type":"other"}'))), isNull);
    expect(parsePackManifest(Uint8List.fromList([1, 2, 3])), isNull);
  });

  test('картинки из файлов и архива ZIP', () {
    final png = Uint8List.fromList(img.encodePng(img.Image(width: 4, height: 4)));
    final arc = Archive()
      ..addFile(ArchiveFile('a.png', png.length, png))
      ..addFile(ArchiveFile('dir/b.png', png.length, png))
      ..addFile(ArchiveFile('__MACOSX/._c.png', 3, [1, 2, 3]))
      ..addFile(ArchiveFile('readme.txt', 2, [65, 66]));
    final zip = Uint8List.fromList(ZipEncoder().encode(arc));
    final out = imagesFromFiles([(zip, 'pack.zip'), (png, 'd.png'), (Uint8List(4), 'x.exe')]);
    expect(out.map((e) => e.$2).toList(), ['a.png', 'b.png', 'd.png']);
  });

  test('стикер: PNG до 512 точек; анимированный GIF остаётся GIF без комментариев', () {
    final big = Uint8List.fromList(img.encodeJpg(img.Image(width: 1024, height: 512)));
    final (_, mime, w, h) = prepareSticker((big, 'p.jpg'))!;
    expect((mime, w, h), ('image/png', 512, 256));

    final anim = img.Image(width: 8, height: 8)..addFrame(img.Image(width: 8, height: 8));
    expect(anim.numFrames, 2);
    final gif = img.encodeGif(anim);
    // комментарий «автор» после заголовка и палитры
    final withComment = _insertGifComment(Uint8List.fromList(gif), 'author-secret');
    expect(String.fromCharCodes(withComment).contains('author-secret'), isTrue);
    final cleaned = stripGifComments(withComment);
    expect(String.fromCharCodes(cleaned).contains('author-secret'), isFalse);
    expect(img.decodeGif(cleaned), isNotNull);
    expect(cleanPackText('  a\u200Bb  '), 'a b');
  });
}

Uint8List _insertGifComment(Uint8List g, String text) {
  var i = 13;
  final flags = g[10];
  if (flags & 0x80 != 0) i += 3 * (1 << ((flags & 7) + 1));
  final c = [0x21, 0xFE, text.length, ...text.codeUnits, 0];
  return Uint8List.fromList([...g.sublist(0, i), ...c, ...g.sublist(i)]);
}
