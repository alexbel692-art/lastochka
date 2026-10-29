// Наборы стикеров, как в Telegram:
// • свои наборы с названием — сколько угодно (кроме «Моих стикеров», совместимых с Element/Cinny);
// • набор целиком — по нажатию на чужой стикер: в отправленный стикер Ласточка кладёт ссылку на
//   «опись» набора (небольшой JSON на вашем сервере), получатель видит набор и добавляет его одной кнопкой;
// • скачать набор архивом (ZIP с картинками) и собрать набор из картинок или архива с компьютера.
//
// Наборы хранятся в данных аккаунта (app.lastochka.sticker_packs) — видны на всех ваших устройствах.
// Стикеры в Matrix не шифруются (как и в Element): картинки лежат на сервере открыто.
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:matrix/matrix.dart';

import '../main.dart';
import '../system/diag.dart';

const packsType = 'app.lastochka.sticker_packs';
const ownType = 'im.ponies.user_emotes';
/// Ключ ссылки на набор в событии стикера.
const packRefKey = 'app.lastochka.pack';
const ownPackId = 'own';
const maxPackItems = 200;

class PackItem {
  final String key, body;
  final Uri url;
  final Map<String, Object?> info;
  const PackItem(this.key, this.body, this.url, this.info);
  Map<String, Object?> toJson() => {'url': '$url', 'body': body, 'info': info, 'usage': ['sticker']};
}

class UserPack {
  final String id, name;
  final List<PackItem> items;
  /// Набор добавлен из чужой «описи» — её адрес (чтобы не добавить дважды).
  final String? source;
  const UserPack(this.id, this.name, this.items, {this.source});
}

/// Имя без управляющих и «переворачивающих» символов, не длиннее [max].
String cleanPackText(Object? v, {int max = 64, String fallback = ''}) {
  if (v is! String) return fallback;
  final s = v.replaceAll(RegExp(r'[\u0000-\u001f\u007f\u200B-\u200F\u202A-\u202E\u2066-\u2069\uFEFF]'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
  if (s.isEmpty) return fallback;
  return s.length > max ? s.substring(0, max) : s;
}

List<PackItem> _items(Object? images) {
  final out = <PackItem>[];
  if (images is! Map) return out;
  for (final MapEntry(:key, :value) in images.entries) {
    if (value is! Map) continue;
    final usage = value['usage'];
    if (usage is List && usage.isNotEmpty && !usage.contains('sticker')) continue;
    final url = Uri.tryParse('${value['url'] ?? ''}');
    if (url == null || url.scheme != 'mxc' || url.host.isEmpty) continue;
    final info = value['info'] is Map ? Map<String, Object?>.from(value['info'] as Map) : <String, Object?>{};
    out.add(PackItem('$key', cleanPackText(value['body'], fallback: 'Стикер'), url, info));
    if (out.length >= maxPackItems) break;
  }
  return out;
}

Map<String, Object?> _packsData() => Map<String, Object?>.from(client.accountData[packsType]?.content ?? const {});

List<Map<String, Object?>> _rawPacks() => [
      for (final p in (_packsData()['packs'] as List?) ?? const [])
        if (p is Map) Map<String, Object?>.from(p),
    ];

/// Свои наборы (без «Моих стикеров»).
List<UserPack> userPacks() => [
      for (final p in _rawPacks())
        if (p['id'] is String)
          UserPack(p['id'] as String, cleanPackText(p['name'], fallback: 'Набор'), _items(p['images']), source: p['source'] as String?),
    ];

UserPack? userPack(String id) => userPacks().where((p) => p.id == id).firstOrNull;

Future<void> _savePacks(List<Map<String, Object?>> packs) =>
    client.setAccountData(client.userID!, packsType, {..._packsData(), 'packs': packs});

String _newId() => 'p_${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}${Random.secure().nextInt(1 << 20).toRadixString(36)}';

Future<String> createPack(String name) async {
  final id = _newId();
  await _savePacks([..._rawPacks(), {'id': id, 'name': cleanPackText(name, fallback: 'Новый набор'), 'images': <String, Object?>{}}]);
  return id;
}

Future<void> renamePack(String id, String name) async {
  await _savePacks([
    for (final p in _rawPacks()) p['id'] == id ? {...p, 'name': cleanPackText(name, fallback: 'Набор'), 'manifest': null} : p,
  ]);
}

Future<void> deletePack(String id) => _savePacks(_rawPacks().where((p) => p['id'] != id).toList());

// ---------- картинки набора (свой набор или «Мои стикеры») ----------

Map<String, Object?> packImages(String packId) {
  if (packId == ownPackId) return Map<String, Object?>.from((client.accountData[ownType]?.content['images'] as Map?) ?? const {});
  final p = _rawPacks().where((p) => p['id'] == packId).firstOrNull;
  return Map<String, Object?>.from((p?['images'] as Map?) ?? const {});
}

Future<void> _setImages(String packId, Map<String, Object?> images) async {
  if (packId == ownPackId) {
    final prev = Map<String, Object?>.from(client.accountData[ownType]?.content ?? const {});
    await client.setAccountData(client.userID!, ownType, {
      ...prev,
      'pack': {'display_name': 'Мои стикеры', ...(prev['pack'] as Map? ?? {})},
      'images': images,
      'app.lastochka.manifest': null, // набор изменился — опись пересоздастся при следующей отправке
    });
    return;
  }
  await _savePacks([
    for (final p in _rawPacks()) p['id'] == packId ? {...p, 'images': images, 'manifest': null} : p,
  ]);
}

String freeKey(Map<String, Object?> images, String name) {
  var base = name.replaceAll(RegExp(r'\.[a-z0-9]+$', caseSensitive: false), '').replaceAll(RegExp(r'[^\p{L}\p{N}_-]+', unicode: true), '_');
  if (base.isEmpty) base = 'sticker';
  if (base.length > 32) base = base.substring(0, 32);
  var k = base;
  for (var n = 2; images.containsKey(k); n++) {
    k = '${base}_$n';
  }
  return k;
}

/// Картинка → стикер: до 512 точек, без сведений о съёмке, PNG. GIF остаётся анимированным
/// (если не больше 1 МБ и 512 точек), но тоже без комментариев. null — не картинка.
(Uint8List, String, int, int)? prepareSticker((Uint8List, String) a) {
  final (bytes, name) = a;
  final isGif = bytes.length > 6 && String.fromCharCodes(bytes.sublist(0, 3)) == 'GIF';
  if (isGif) {
    final g = img.decodeGif(bytes);
    if (g != null && g.numFrames > 1 && bytes.length <= 1024 * 1024 && g.width <= 512 && g.height <= 512) {
      return (stripGifComments(bytes), 'image/gif', g.width, g.height);
    }
  }
  var im = img.decodeImage(bytes);
  if (im == null) return null;
  im = img.bakeOrientation(im);
  if (im.width > 512 || im.height > 512) {
    im = im.width >= im.height ? img.copyResize(im, width: 512) : img.copyResize(im, height: 512);
  }
  im.exif = img.ExifData();
  im.textData = null;
  return (img.encodePng(im), 'image/png', im.width, im.height);
}

/// GIF без блоков-комментариев (в них иногда пишут автора, программу и т. п.). Повреждённый — как есть.
Uint8List stripGifComments(Uint8List b) {
  try {
    if (b.length < 13) return b;
    final out = BytesBuilder(copy: false);
    var i = 13;
    final flags = b[10];
    if (flags & 0x80 != 0) i += 3 * (1 << ((flags & 7) + 1));
    out.add(Uint8List.sublistView(b, 0, i));
    int subBlocks(int j) {
      while (j < b.length && b[j] != 0) {
        j += b[j] + 1;
      }
      return j + 1;
    }

    while (i < b.length) {
      final t = b[i];
      if (t == 0x3B) {
        out.addByte(0x3B);
        return out.toBytes();
      } else if (t == 0x21) {
        final label = b[i + 1];
        final end = subBlocks(i + 2);
        if (label != 0xFE) out.add(Uint8List.sublistView(b, i, end)); // 0xFE — комментарий
        i = end;
      } else if (t == 0x2C) {
        var j = i + 10;
        final f = b[i + 9];
        if (f & 0x80 != 0) j += 3 * (1 << ((f & 7) + 1));
        j = subBlocks(j + 1); // минимальный размер кода + данные
        out.add(Uint8List.sublistView(b, i, j));
        i = j;
      } else {
        return b;
      }
    }
    return b;
  } catch (_) {
    return b;
  }
}

/// Добавить картинки в набор. Возвращает, сколько добавлено.
Future<int> addImagesToPack(String packId, List<(Uint8List, String)> files) async {
  final images = packImages(packId);
  var added = 0;
  for (final (bytes, name) in files) {
    if (images.length >= maxPackItems) break;
    try {
      final s = await compute(prepareSticker, (bytes, name));
      if (s == null) continue;
      final (data, mime, w, h) = s;
      final uri = await client.uploadContent(data, filename: mime == 'image/gif' ? 'sticker.gif' : 'sticker.png', contentType: mime);
      images[freeKey(images, name)] = {
        'url': uri.toString(),
        'body': 'Стикер',
        'info': {'w': w, 'h': h, 'mimetype': mime, 'size': data.length},
        'usage': ['sticker'],
      };
      added++;
    } catch (e) {
      Diag.err('Стикер в набор', e);
    }
  }
  if (added > 0) await _setImages(packId, images);
  return added;
}

Future<void> removeFromPack(String packId, String key) async {
  final images = packImages(packId)..remove(key);
  await _setImages(packId, images);
}

/// Картинки из выбранных файлов: изображения как есть, ZIP — распаковываются (только картинки,
/// не больше [maxPackItems] и 30 МБ в сумме; вложенные папки и чужие пути игнорируются).
List<(Uint8List, String)> imagesFromFiles(List<(Uint8List, String)> files) {
  final out = <(Uint8List, String)>[];
  var total = 0;
  final pic = RegExp(r'\.(png|jpe?g|webp|gif)$', caseSensitive: false);
  for (final (bytes, name) in files) {
    if (out.length >= maxPackItems) break;
    if (name.toLowerCase().endsWith('.zip')) {
      try {
        final arc = ZipDecoder().decodeBytes(bytes);
        for (final f in arc.files) {
          if (!f.isFile || !pic.hasMatch(f.name) || f.size > 5 * 1024 * 1024) continue;
          if (f.name.contains('__MACOSX') || f.name.split('/').last.startsWith('.')) continue;
          total += f.size;
          if (total > 30 * 1024 * 1024 || out.length >= maxPackItems) break;
          out.add((Uint8List.fromList(f.content as List<int>), f.name.split('/').last));
        }
      } catch (e) {
        Diag.err('Архив стикеров', e);
      }
    } else if (pic.hasMatch(name) && bytes.length <= 5 * 1024 * 1024) {
      total += bytes.length;
      if (total > 30 * 1024 * 1024) break;
      out.add((bytes, name));
    }
  }
  return out;
}

// ---------- скачивание ----------

/// Файл с сервера по mxc:// (стикеры не зашифрованы). null — не получилось или больше [max].
Future<Uint8List?> downloadMxc(Uri mxc, {int max = 5 * 1024 * 1024}) async {
  try {
    final hs = client.homeserver;
    if (hs == null || mxc.scheme != 'mxc') return null;
    final url = hs.resolveUri(Uri(path: '/_matrix/client/v1/media/download/${mxc.host}${mxc.path}'));
    final res = await client.httpClient.get(url, headers: {'authorization': 'Bearer ${client.accessToken}'});
    if (res.statusCode != 200 || res.bodyBytes.length > max) return null;
    return res.bodyBytes;
  } catch (_) {
    return null;
  }
}

String _ext(String? mime) => switch (mime) { 'image/gif' => 'gif', 'image/webp' => 'webp', 'image/jpeg' => 'jpg', _ => 'png' };

/// Набор архивом: картинки и опись pack.json (её понимает «Собрать из файлов»).
Future<Uint8List> packZip(String name, List<PackItem> items) async {
  final arc = Archive();
  var n = 0;
  for (final it in items) {
    final b = await downloadMxc(it.url);
    if (b == null) continue;
    n++;
    arc.addFile(ArchiveFile('${n.toString().padLeft(3, '0')}_${freeKey(const {}, it.key)}.${_ext(it.info['mimetype'] as String?)}', b.length, b));
  }
  final meta = utf8.encode(jsonEncode({'name': name, 'count': n}));
  arc.addFile(ArchiveFile('pack.json', meta.length, meta));
  return Uint8List.fromList(ZipEncoder().encode(arc));
}

// ---------- опись набора и «Добавить набор» ----------

/// Ссылка на опись набора для отправляемого стикера; опись создаётся при первой отправке
/// (и заново, если набор изменился). Встроенные наборы и наборы чатов — без описи.
Future<Map<String, Object?>?> packRefFor(String packId) async {
  try {
    final String name;
    final List<PackItem> items;
    String? manifest;
    if (packId == ownPackId) {
      final c = client.accountData[ownType]?.content ?? const {};
      name = 'Стикеры';
      items = _items(c['images']);
      manifest = c['app.lastochka.manifest'] as String?;
    } else {
      final p = _rawPacks().where((p) => p['id'] == packId).firstOrNull;
      if (p == null) return null;
      name = cleanPackText(p['name'], fallback: 'Набор');
      items = _items(p['images']);
      manifest = p['manifest'] as String?;
    }
    if (items.isEmpty) return null;
    if (manifest == null) {
      final body = utf8.encode(jsonEncode({
        'type': 'app.lastochka.sticker_pack',
        'name': name,
        'images': {for (final it in items) it.key: it.toJson()},
      }));
      final uri = await client.uploadContent(Uint8List.fromList(body), filename: 'pack.json', contentType: 'application/json');
      manifest = uri.toString();
      if (packId == ownPackId) {
        final prev = Map<String, Object?>.from(client.accountData[ownType]?.content ?? const {});
        await client.setAccountData(client.userID!, ownType, {...prev, 'app.lastochka.manifest': manifest});
      } else {
        await _savePacks([for (final p in _rawPacks()) p['id'] == packId ? {...p, 'manifest': manifest} : p]);
      }
    }
    return {'name': name, 'manifest': manifest, 'count': items.length};
  } catch (e) {
    Diag.err('Опись набора стикеров', e);
    return null;
  }
}

/// Чужой набор по ссылке из стикера: (название, стикеры). null — не загрузился или испорчен.
Future<(String, List<PackItem>)?> fetchPack(Map ref) async {
  final m = Uri.tryParse('${ref['manifest'] ?? ''}');
  if (m == null || m.scheme != 'mxc') return null;
  final b = await downloadMxc(m, max: 512 * 1024);
  if (b == null) return null;
  return parsePackManifest(b, fallbackName: cleanPackText(ref['name'], fallback: 'Набор'));
}

(String, List<PackItem>)? parsePackManifest(Uint8List bytes, {String fallbackName = 'Набор'}) {
  try {
    final j = jsonDecode(utf8.decode(bytes));
    if (j is! Map || j['type'] != 'app.lastochka.sticker_pack') return null;
    final items = _items(j['images']);
    if (items.isEmpty) return null;
    return (cleanPackText(j['name'], fallback: fallbackName), items);
  } catch (_) {
    return null;
  }
}

bool packAdded(String manifest) => _rawPacks().any((p) => p['source'] == manifest);

/// Добавить чужой набор себе (копия списка: стикеры остаются у вас, даже если автор свой набор изменит).
Future<void> addPackFromManifest(String manifest, String name, List<PackItem> items) async {
  if (packAdded(manifest)) return;
  await _savePacks([
    ..._rawPacks(),
    {
      'id': _newId(),
      'name': cleanPackText(name, fallback: 'Набор'),
      'source': manifest,
      'images': {for (final it in items.take(maxPackItems)) it.key: it.toJson()},
    },
  ]);
}
