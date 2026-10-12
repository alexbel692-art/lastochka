import 'package:flutter_test/flutter_test.dart';
import 'package:lastochka/system/link_safety.dart';

void main() {
  test('punycode', () {
    expect(punyDecode('xn--80aswg'), 'сайт');
    expect(displayHost('xn--d1acpjx3f.xn--p1ai'), 'яндекс.рф');
  });

  test('обычные ссылки — без предупреждений', () {
    expect(linkWarnings(Uri.parse('https://rostender.info/region/x')), isEmpty);
    expect(linkWarnings(Uri.parse('https://xn--d1acpjx3f.xn--p1ai/')), isEmpty);
    expect(linkWarnings(Uri.parse('https://www.sberbank.ru/x'), shown: 'sberbank.ru'), isEmpty);
    expect(linkWarnings(Uri.parse('https://online.sberbank.ru/'), shown: 'sberbank.ru'), isEmpty);
  });

  test('подделки', () {
    expect(linkWarnings(Uri.parse('https://evil.example/'), shown: 'sberbank.ru'), isNotEmpty);
    // «sbеrbank» с русской «е»
    expect(linkWarnings(Uri.parse('https://xn--sbrbank-8gg.com/')), isNotEmpty);
    expect(linkWarnings(Uri.parse('http://185.12.3.4/login')), isNotEmpty);
    expect(linkWarnings(Uri.parse('https://sberbank.ru@evil.example/')), isNotEmpty);
  });
}
