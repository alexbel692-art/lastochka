import 'package:flutter_test/flutter_test.dart';
import 'package:lastochka/chat/formatting.dart';

void main() {
  test('ссылка в читаемом виде', () {
    expect(prettyUrl('https://rostender.info/tendery-uslugi-v-oblasti-programmirovaniya'), 'rostender.info/tendery-uslugi-v-oblasti-programmirovaniya');
    expect(prettyUrl('https://www.example.com/'), 'example.com');
    expect(prettyUrl('https://ru.wikipedia.org/wiki/%D0%9B%D0%B0%D1%81%D1%82%D0%BE%D1%87%D0%BA%D0%B0'), 'ru.wikipedia.org/wiki/Ласточка');
    final long = prettyUrl('https://rostender.info/region/moskva-gorod/95506673-tender-prilojenie-s-golosovym-ii-pitomcem');
    expect(long.length, 60);
    expect(long.endsWith('…'), isTrue);
  });

  test('карточка: сайт и раздел', () {
    final p = linkParts('https://rostender.info/region/moskva-gorod/95506673-tender#desc')!;
    expect(p.host, 'rostender.info');
    expect(p.path, 'region › moskva gorod › 95506673 tender');
    expect(linkParts('www.example.com')!.host, 'example.com');
  });
}
