import 'package:flutter_test/flutter_test.dart';
import 'package:lastochka/chat/formatting.dart';

void main() {
  test('ссылка в читаемом виде', () {
    expect(prettyUrl('https://rostender.info/tendery-uslugi-v-oblasti-programmirovaniya'), 'rostender.info/tendery-uslugi-v-oblasti-programmirovaniya');
    expect(prettyUrl('https://www.example.com/'), 'example.com');
    expect(prettyUrl('https://ru.wikipedia.org/wiki/%D0%9B%D0%B0%D1%81%D1%82%D0%BE%D1%87%D0%BA%D0%B0'), 'ru.wikipedia.org/wiki/Ласточка');
    final long = prettyUrl('https://rostender.info/region/moskva-gorod/95506673-tender-prilojenie-s-golosovym-ii-pitomcem');
    expect(long.length, 60);
    expect(long.startsWith('rostender.info…'), isTrue); // сайт виден всегда
    expect(long.endsWith('pitomcem'), isTrue);
    // длинный поддельный адрес: виден настоящий сайт в конце, а не «sberbank.ru»
    final fake = prettyUrl('https://sberbank.ru.secure-login-verify-account-now-please-click-here.evil.com/x');
    expect(fake.endsWith('evil.com'), isTrue);
    // невидимые символы «переворота» текста убираются
    expect(prettyUrl('https://example.com/a%E2%80%AEtxt.exe'), 'example.com/atxt.exe');
  });

  test('карточка: сайт и раздел', () {
    final p = linkParts('https://rostender.info/region/moskva-gorod/95506673-tender#desc')!;
    expect(p.host, 'rostender.info');
    expect(p.path, 'region › moskva gorod › 95506673 tender');
    expect(linkParts('www.example.com')!.host, 'example.com');
  });
}
