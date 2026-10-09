// Подпись обновлений: настоящая подпись релиза 3.28.0 должна проходить, подделка — нет.
import 'package:flutter_test/flutter_test.dart';
import 'package:lastochka/system/updater.dart';

const real = {
  'version': '3.28.0',
  'file': 'Lastochka-Setup-3.28.0.exe',
  'sha256': 'f467717a1100947d6ce891967b13aadd5f44a2d0c56ed74aff84ef76d4af743d',
  'sig': 'Vs8x2vh/YrFhcQxrOC8Mu5odIs9Rv6oY+ZGpVc60l9BW2nSiiS2eJH5KocKWh2U9YYPbnC2KUyrRWbXKF6/qDQ==',
};

void main() {
  test('настоящая подпись принимается', () async {
    expect(await verifyUpdateSignature(Map.of(real)), isTrue);
  });
  test('подменённый файл не принимается', () async {
    expect(await verifyUpdateSignature({...real, 'sha256': '0' * 64}), isFalse);
    expect(await verifyUpdateSignature({...real, 'version': '9.9.9'}), isFalse);
    expect(await verifyUpdateSignature({...real, 'sig': 'AAAA'}), isFalse);
  });
  test('сравнение версий', () {
    expect(cmpVer('4.0.0', '3.28.0') > 0, isTrue);
    expect(cmpVer('4.0.1', '4.0.0') > 0, isTrue);
    expect(cmpVer('4.0.0', '4.0.0'), 0);
  });
}
