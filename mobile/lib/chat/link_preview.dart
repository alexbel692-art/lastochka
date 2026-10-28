// Превью ссылки под сообщением: сайт, заголовок, описание и картинка — как в Telegram.
//
// Страницу открывает ваш Matrix-сервер (запрос /preview_url), а не устройство: сайт не узнаёт адрес
// и устройство человека, а картинка приходит уже с вашего сервера. Если на сервере превью выключены,
// карточка просто не появляется. Сайт подписан настоящим адресом из ссылки, а не названием,
// которое указала сама страница, — под чужой сайт так не замаскироваться. Нажатие открывает ссылку
// тем же путём, что и в тексте: с подтверждением и проверкой на поддельные адреса.
// Выключено — карточка остаётся простой: сайт и раздел, без загрузки страницы.
import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../main.dart' show client;
import '../system/lru.dart';
import '../widgets/mxc_image.dart';

/// Показывать превью ссылок (настройка «Конфиденциальность → Превью ссылок»).
final linkPreviews = ValueNotifier<bool>(true);

Future<void> initLinkPreviews() async {
  linkPreviews.value = (await SharedPreferences.getInstance()).getBool('privacy.linkPreviews') ?? true;
}

Future<void> setLinkPreviews(bool on) async {
  linkPreviews.value = on;
  await (await SharedPreferences.getInstance()).setBool('privacy.linkPreviews', on);
}

final _urlRe = RegExp(r'''(?:https?://|www\.)[^\s<>"']+[^\s<>"'.,;:!?)\]}]''', caseSensitive: false);

/// Первая ссылка в тексте (http/https), кроме ссылок на людей и чаты Matrix. null — ссылки нет.
Uri? firstLink(String text) {
  for (final m in _urlRe.allMatches(text)) {
    var u = m[0]!;
    if (u.toLowerCase().startsWith('www.')) u = 'https://$u';
    final uri = Uri.tryParse(u);
    if (uri == null || uri.host.isEmpty || !const ['http', 'https'].contains(uri.scheme.toLowerCase())) continue;
    if (uri.host == 'matrix.to') continue;
    return uri;
  }
  return null;
}

class LinkInfo {
  final String? title, description;
  final Uri? image;
  const LinkInfo(this.title, this.description, this.image);
  bool get isEmpty => (title ?? '').isEmpty && (description ?? '').isEmpty && image == null;
}

final _cache = Lru<String, Future<LinkInfo?>>(150)..register();

String? _clean(Object? v, int max) {
  if (v is! String) return null;
  final s = v.replaceAll(RegExp(r'[\u0000-\u001f\u007f\u200b-\u200f\u202a-\u202e\u2066-\u2069\ufeff]'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
  if (s.isEmpty) return null;
  return s.length > max ? '${s.substring(0, max)}…' : s;
}

Future<LinkInfo?> linkInfo(Uri url) => _cache.putIfAbsent(url.toString(), () async {
      try {
        final p = await client.getUrlPreview(url).timeout(const Duration(seconds: 15));
        final a = p.additionalProperties;
        final img = p.ogImage;
        final info = LinkInfo(
          _clean(a['og:title'], 200),
          _clean(a['og:description'], 300),
          img != null && img.scheme == 'mxc' ? img : null,
        );
        return info.isEmpty ? null : info;
      } catch (e) {
        // превью выключены на сервере, сайт недоступен и т. п. — без карточки
        Logs().v('[Ласточка] превью ссылки не получено', e);
        return null;
      }
    });

/// Заголовок, описание и картинка сайта — дополняют карточку ссылки под сообщением (formatting.dart).
class LinkInfoBody extends StatelessWidget {
  final LinkInfo info;
  final Color textColor;
  const LinkInfoBody({super.key, required this.info, required this.textColor});

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        if (info.title != null)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(info.title!, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14, color: textColor)),
          ),
        if (info.description != null)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(info.description!, maxLines: 3, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13.5, color: textColor.withValues(alpha: 0.8), height: 1.25)),
          ),
        if (info.image != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: ConstrainedBox(constraints: const BoxConstraints(maxHeight: 180, maxWidth: 360), child: MxcImage(mxc: info.image!, size: 400)),
            ),
          ),
      ]);
}
