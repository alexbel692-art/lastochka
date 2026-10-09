// Проверка посредника звонков на векторах, посчитанных эталонной реализацией
// (она сверена с RFC 5769). Запускается при каждой сборке.
import 'package:flutter_test/flutter_test.dart';
import 'package:lastochka/calls/turn_proxy.dart';

List<int> hex(String s) => [for (var i = 0; i < s.length; i += 2) int.parse(s.substring(i, i + 2), radix: 16)];
String toHex(List<int> b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

const aHex = '000300102112a4420102030405060708090a0b0c00190004110000008028000441c778f0';
const cliHex = '000300482112a4420102030405060708090a0b0c00190004110000000006000175000000001400096c6173746f63686b61000000001500036162630000080014a148581a7bffe1c7f6a7519a83382e6a32b5c78c80280004ce14cb35';
const fwdHex = '000300102112a4420102030405060708090a0b0c00190004110000008028000441c778f0';
const srvHex = '010300382112a4420102030405060708090a0b0c001600080001e112c0a8a1b2002000080001e1125e12a443000d0004000002588022000a436f7475726e2d342e36000080280004b147e5c0';
const signedHex = '010300502112a4420102030405060708090a0b0c001600080001e112c0a8a1b2002000080001e1125e12a443000d0004000002588022000a436f7475726e2d342e360000000800142bdb041ec66e8d4a5bacc8ddc57d8546e6001d71802800047dc87310';
const err401Hex = '011300342112a4420102030405060708090a0b0c0009001000000401556e617574686f72697a6564001400096c6173746f63686b610000000015000361626300802800048a3207d4';

void main() {
  test('Allocate без логина → 401 от посредника', () {
    final shim = TurnShim({'u': 'p'}, nonce: 'abc');
    List<int>? replied, forwarded;
    shim.up(hex(aHex), (r) => replied = r, (f) => forwarded = f);
    expect(forwarded, isNull);
    expect(toHex(replied!), err401Hex);
  });

  test('Allocate с подписью → на сервер без подписи, ответ сервера подписан', () {
    final shim = TurnShim({'u': 'p'}, nonce: 'abc');
    List<int>? forwarded;
    shim.up(hex(cliHex), (_) => fail('не должно отвечать'), (f) => forwarded = f);
    expect(toHex(forwarded!), fwdHex);
    expect(toHex(shim.down(hex(srvHex))), signedHex);
  });

  test('Нарезка TCP-потока на кадры', () {
    final frames = <String>[];
    final f = StunFramer((x) => frames.add(toHex(x)));
    final all = [...hex(srvHex), ...hex(aHex), 0x40, 0x00, 0x00, 0x03, 1, 2, 3, 0];
    f.add(all.sublist(0, 7));
    f.add(all.sublist(7, 70));
    f.add(all.sublist(70));
    expect(frames, [srvHex, aHex, '4000000301020300']);
  });
}
