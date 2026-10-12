// Проверка ссылок перед открытием: текст ссылки ведёт не туда, адрес из похожих букв
// (латинская «а» вместо русской, «xn--…»), адрес — голый IP. Только подсказки человеку:
// никуда ничего не отправляется.

/// Разобрать адрес «xn--…» (Punycode, RFC 3492) в обычные буквы.
String punyDecode(String label) {
  if (!label.startsWith('xn--')) return label;
  final input = label.substring(4);
  const base = 36, tMin = 1, tMax = 26, skew = 38, damp = 700;
  var n = 128, i = 0, bias = 72;
  final out = <int>[];
  final d = input.lastIndexOf('-');
  if (d > 0) out.addAll(input.substring(0, d).codeUnits);
  var pos = d > 0 ? d + 1 : 0;
  int adapt(int delta, int numPoints, bool first) {
    delta = first ? delta ~/ damp : delta ~/ 2;
    delta += delta ~/ numPoints;
    var k = 0;
    while (delta > ((base - tMin) * tMax) ~/ 2) {
      delta ~/= base - tMin;
      k += base;
    }
    return k + (base - tMin + 1) * delta ~/ (delta + skew);
  }

  try {
    while (pos < input.length) {
      final oldi = i;
      var w = 1;
      for (var k = base;; k += base) {
        if (pos >= input.length) return label;
        final c = input.codeUnitAt(pos++);
        final digit = c - 48 < 10 ? c - 22 : c - 65 < 26 ? c - 65 : c - 97 < 26 ? c - 97 : base;
        if (digit >= base) return label;
        i += digit * w;
        final t = k <= bias ? tMin : (k >= bias + tMax ? tMax : k - bias);
        if (digit < t) break;
        w *= base - t;
      }
      bias = adapt(i - oldi, out.length + 1, oldi == 0);
      n += i ~/ (out.length + 1);
      i %= out.length + 1;
      out.insert(i, n);
      i++;
    }
    return String.fromCharCodes(out);
  } catch (_) {
    return label;
  }
}

/// Имя сайта человеческими буквами.
String displayHost(String host) {
  var h = host;
  try {
    h = Uri.decodeComponent(h);
  } catch (_) {}
  return h.toLowerCase().split('.').map(punyDecode).join('.');
}

final _lat = RegExp(r'[a-z]');
final _cyr = RegExp(r'[а-яё]');
final _ipv4 = RegExp(r'^\d{1,3}(\.\d{1,3}){3}$');

/// Что подозрительного в ссылке (пустой список — всё в порядке).
List<String> linkWarnings(Uri uri, {String? shown}) {
  final out = <String>[];
  final host = displayHost(uri.host);
  final labels = host.split('.');
  final tld = labels.isEmpty ? '' : labels.last;
  // буквы разных алфавитов в одном слове адреса: «sbеrbank» с русской «е»
  if (labels.any((l) => _lat.hasMatch(l) && _cyr.hasMatch(l))) {
    out.add('В адресе смешаны латинские и русские буквы — так подделывают известные сайты');
  } else if (labels.take(labels.length - 1).any((l) => _cyr.hasMatch(l)) && !_cyr.hasMatch(tld) && const {'com', 'net', 'org', 'info', 'io', 'app'}.contains(tld)) {
    out.add('Адрес написан русскими буквами в зоне .$tld — проверьте, что это нужный сайт');
  }
  if (uri.host.contains('xn--') && !_cyr.hasMatch(host)) {
    out.add('Адрес закодирован (xn--…) и содержит необычные символы');
  } else if (out.isEmpty && RegExp(r'[^\x00-\x7f]').hasMatch(host) && labels.any((l) => RegExp(r'[^a-z0-9а-яё-]').hasMatch(l))) {
    // буквы-двойники из других алфавитов (ѕ, і, ј, греческая ο…), которые не попадают в «русские»
    out.add('В адресе необычные буквы, похожие на латинские, — так подделывают известные сайты');
  }
  if (_ipv4.hasMatch(uri.host) || uri.host.startsWith('[')) {
    out.add('Вместо имени сайта — числовой адрес');
  }
  if (uri.userInfo.isNotEmpty) {
    out.add('Перед адресом спрятано «${uri.userInfo}@» — настоящий сайт: $host');
  }
  // текст ссылки похож на адрес, но ведёт на другой сайт
  final s = shown?.trim() ?? '';
  final m = RegExp(r'^(?:https?://)?(?:www\.)?([a-zа-яё0-9-]+(?:\.[a-zа-яё0-9-]+)+)', caseSensitive: false).firstMatch(s);
  if (m != null) {
    final shownHost = displayHost(m[1]!).replaceFirst(RegExp(r'^www\.'), '');
    final real = host.replaceFirst(RegExp(r'^www\.'), '');
    if (shownHost != real && !real.endsWith('.$shownHost')) {
      out.add('Текст ссылки показывает «$shownHost», а на самом деле она ведёт на «$real»');
    }
  }
  return out;
}
