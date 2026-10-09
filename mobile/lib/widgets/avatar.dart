import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../main.dart';

// Кэш миниатюр в памяти, чтобы список чатов не мигал при прокрутке.
final Map<String, Uint8List> _thumbs = {};
final Map<String, Future<Uint8List?>> _loading = {};

/// Загружает миниатюру mxc:// через авторизованный доступ к медиа.
Future<Uint8List?> loadThumb(Uri mxc, int size, {String method = 'crop'}) {
  final key = '$mxc@$size$method';
  if (_thumbs.containsKey(key)) return Future.value(_thumbs[key]);
  return _loading[key] ??= () async {
    try {
      final hs = client.homeserver;
      if (hs == null || mxc.scheme != 'mxc') return null;
      final url = hs.resolveUri(Uri(
        path: '/_matrix/client/v1/media/thumbnail/${mxc.host}${mxc.path}',
        queryParameters: {'width': '$size', 'height': '$size', 'method': method},
      ));
      final res = await client.httpClient.get(url, headers: {'authorization': 'Bearer ${client.accessToken}'});
      if (res.statusCode != 200) return null;
      return _thumbs[key] = res.bodyBytes;
    } catch (_) {
      return null;
    } finally {
      _loading.remove(key);
    }
  }();
}

const _palette = [
  Color(0xFFFF845E), Color(0xFF9AD164), Color(0xFFD27EEC), Color(0xFF5CAFFA),
  Color(0xFF5BCBE3), Color(0xFFFFAF51), Color(0xFFF07BA8),
];

class Avatar extends StatelessWidget {
  final Uri? mxc;
  final String name;
  final double size;
  const Avatar({super.key, required this.mxc, required this.name, this.size = 52});

  @override
  Widget build(BuildContext context) {
    final letters = name.trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).take(2).map((w) => w.characters.first.toUpperCase()).join();
    final color = _palette[name.hashCode.abs() % _palette.length];
    final fallback = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [color.withValues(alpha: 0.8), color]),
      ),
      alignment: Alignment.center,
      child: Text(letters.isEmpty ? '?' : letters, style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: size * 0.38)),
    );
    if (mxc == null) return fallback;
    final px = (size * MediaQuery.devicePixelRatioOf(context)).round().clamp(64, 512);
    return FutureBuilder<Uint8List?>(
      future: loadThumb(mxc!, px),
      builder: (_, s) => s.data == null
          ? fallback
          : ClipOval(child: Image.memory(s.data!, width: size, height: size, fit: BoxFit.cover, gaplessPlayback: true)),
    );
  }
}
