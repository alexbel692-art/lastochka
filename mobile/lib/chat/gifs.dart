// GIF, как в Telegram: вкладка «GIF» в панели эмодзи и стикеров.
// • «Мои GIF» — сохранённые из чатов (данные аккаунта app.lastochka.gifs, видны на всех ваших устройствах;
//   сами файлы лежат на вашем сервере без шифрования — как стикеры).
// • Поиск — через GIPHY (Tenor от Google закрыт в 2026 году). Нужен ключ GIPHY: вписывается при сборке
//   (GIPHY_KEY) или в «Настройки → GIF». Запрос и адрес устройства видит GIPHY, поэтому поиск можно выключить.
//   Найденная GIF скачивается и отправляется как обычная картинка — в защищённом чате она шифруется.
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:matrix/matrix.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../main.dart';
import '../system/diag.dart';
import '../system/trust.dart';
import 'autodelete.dart';
import 'sticker_packs.dart' show downloadMxc, stripGifComments;

const gifsType = 'app.lastochka.gifs';
const _buildKey = String.fromEnvironment('GIPHY_KEY');
const maxGifBytes = 8 * 1024 * 1024;
const maxSavedGifs = 100;

/// Сохранённая GIF (на вашем сервере).
class SavedGif {
  final Uri url;
  final int w, h, size;
  const SavedGif(this.url, this.w, this.h, this.size);
  Map<String, Object?> toJson() => {'url': '$url', 'w': w, 'h': h, 'size': size};
}

/// Найденная в GIPHY.
class GifResult {
  final String id, preview, still, full;
  final int w, h;
  const GifResult(this.id, this.preview, this.still, this.full, this.w, this.h);
}

// ---------- настройки поиска ----------

Future<String> giphyKey() async {
  final own = (await SharedPreferences.getInstance()).getString('gif.giphyKey')?.trim() ?? '';
  return own.isNotEmpty ? own : _buildKey;
}

Future<bool> gifSearchOn() async => (await SharedPreferences.getInstance()).getBool('gif.search') ?? true;

// ---------- мои GIF ----------

List<SavedGif> savedGifs() {
  final list = client.accountData[gifsType]?.content['items'];
  if (list is! List) return const [];
  return [
    for (final x in list)
      if (x is Map && Uri.tryParse('${x['url']}')?.scheme == 'mxc')
        SavedGif(Uri.parse('${x['url']}'), (x['w'] as num?)?.toInt() ?? 0, (x['h'] as num?)?.toInt() ?? 0, (x['size'] as num?)?.toInt() ?? 0),
  ];
}

Future<void> _saveList(List<SavedGif> l) => client.setAccountData(client.userID!, gifsType, {'items': [for (final g in l.take(maxSavedGifs)) g.toJson()]});

bool isGifEvent(Event e) =>
    e.messageType == MessageTypes.Image && (e.content.tryGetMap<String, Object?>('info')?['mimetype'] == 'image/gif' || e.body.toLowerCase().endsWith('.gif'));

/// Размеры и проверка: это действительно GIF. null — нет.
(int, int)? gifSize(Uint8List b) {
  if (b.length < 10 || String.fromCharCodes(b.sublist(0, 3)) != 'GIF') return null;
  final w = b[6] | (b[7] << 8), h = b[8] | (b[9] << 8);
  return w > 0 && h > 0 ? (w, h) : null;
}

/// «Сохранить GIF» из сообщения: копия без шифрования на вашем сервере, в начало списка.
Future<String> saveGifFromEvent(Event e) async {
  try {
    final f = await e.downloadAndDecryptAttachment();
    if (f.bytes.length > maxGifBytes) return 'Слишком большая GIF';
    final clean = stripGifComments(f.bytes);
    final size = gifSize(clean);
    if (size == null) return 'Это не GIF';
    final uri = await client.uploadContent(clean, filename: 'gif.gif', contentType: 'image/gif');
    await _saveList([SavedGif(uri, size.$1, size.$2, clean.length), ...savedGifs()]);
    return 'Сохранено в «Мои GIF»';
  } catch (err) {
    Diag.err('Сохранить GIF', err);
    return 'Не удалось сохранить GIF';
  }
}

Future<void> removeSavedGif(Uri url) => _saveList(savedGifs().where((g) => g.url != url).toList());

/// Отправить сохранённую: ссылка на уже загруженный файл (как стикер, без повторной загрузки).
Future<void> sendSavedGif(Room room, SavedGif g, {Event? inReplyTo}) async {
  ensureCanSend(room);
  await room.sendEvent({
    'msgtype': MessageTypes.Image,
    'body': 'GIF.gif',
    'url': g.url.toString(),
    'info': {'mimetype': 'image/gif', 'w': g.w, 'h': g.h, if (g.size > 0) 'size': g.size},
    ...ttlExtra(room),
  }, inReplyTo: inReplyTo);
}

/// Отправить GIF из файла или поиска (в защищённом чате — зашифрованной).
Future<void> sendGifBytes(Room room, Uint8List bytes, {Event? inReplyTo}) async {
  final clean = stripGifComments(bytes);
  final size = gifSize(clean);
  if (size == null) throw const FormatException('не GIF');
  ensureCanSend(room);
  await room.sendFileEvent(
    MatrixImageFile(bytes: clean, name: 'GIF.gif', mimeType: 'image/gif', width: size.$1, height: size.$2),
    inReplyTo: inReplyTo,
    extraContent: ttlExtra(room),
  );
}

// ---------- GIPHY ----------

/// Поиск (пустой запрос — популярные). [still] — неподвижные превью (RDP: меньше нагрузка).
Future<List<GifResult>> searchGifs(String query, {int offset = 0}) async {
  final key = await giphyKey();
  if (key.isEmpty) return const [];
  final q = query.trim();
  final uri = Uri.https('api.giphy.com', q.isEmpty ? '/v1/gifs/trending' : '/v1/gifs/search', {
    'api_key': key,
    if (q.isNotEmpty) 'q': q,
    'limit': '30',
    'offset': '$offset',
    'rating': 'pg-13',
    'lang': 'ru',
    'bundle': 'messaging_non_clips',
  });
  final res = await http.get(uri).timeout(const Duration(seconds: 15));
  if (res.statusCode != 200) throw Exception('GIPHY ${res.statusCode}');
  return parseGiphy(res.body);
}

List<GifResult> parseGiphy(String body) {
  final j = jsonDecode(body);
  final data = j is Map ? j['data'] : null;
  if (data is! List) return const [];
  final out = <GifResult>[];
  String? u(Map? m) {
    final s = m?['url'];
    if (s is! String) return null;
    final p = Uri.tryParse(s);
    // только https с серверов GIPHY
    return p != null && p.scheme == 'https' && (p.host == 'giphy.com' || p.host.endsWith('.giphy.com')) ? s : null;
  }

  for (final x in data) {
    if (x is! Map) continue;
    final im = x['images'];
    if (im is! Map) continue;
    final small = u(im['fixed_width_small'] as Map?) ?? u(im['fixed_width'] as Map?);
    final still = u(im['fixed_width_small_still'] as Map?) ?? u(im['fixed_width_still'] as Map?) ?? small;
    final full = im['fixed_height'] as Map?;
    final fullUrl = u(full) ?? u(im['downsized'] as Map?);
    if (small == null || still == null || fullUrl == null) continue;
    int n(Object? v) => int.tryParse('$v') ?? 0;
    out.add(GifResult('${x['id']}', small, still, fullUrl, n(full?['width']), n(full?['height'])));
  }
  return out;
}

/// Скачать найденную GIF (не больше [maxGifBytes]).
Future<Uint8List?> downloadGif(String url) async {
  final res = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 30));
  if (res.statusCode != 200 || res.bodyBytes.length > maxGifBytes) return null;
  return gifSize(res.bodyBytes) == null ? null : res.bodyBytes;
}

Future<Uint8List?> savedGifBytes(SavedGif g) => downloadMxc(g.url, max: maxGifBytes);
