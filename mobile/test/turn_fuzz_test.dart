// Фаззинг посредника звонков: миллионы байт случайных и испорченных пакетов не должны
// приводить к падению, зависанию или выходу за границы буфера.
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:lastochka/calls/turn_proxy.dart';

List<int> hex(String s) => [for (var i = 0; i < s.length; i += 2) int.parse(s.substring(i, i + 2), radix: 16)];

const seeds = [
  '000300102112a4420102030405060708090a0b0c00190004110000008028000441c778f0',
  '010300382112a4420102030405060708090a0b0c001600080001e112c0a8a1b2002000080001e1125e12a443000d0004000002588022000a436f7475726e2d342e36000080280004b147e5c0',
  '000300482112a4420102030405060708090a0b0c00190004110000000006000175000000001400096c6173746f63686b61000000001500036162630000080014a148581a7bffe1c7f6a7519a83382e6a32b5c78c80280004ce14cb35',
];

void main() {
  test('случайные и испорченные пакеты не роняют посредника', () {
    final rnd = Random(42);
    final shim = TurnShim({'u': 'p'}, nonce: 'abc');
    var frames = 0;
    final framer = StunFramer((f) {
      frames++;
      shim.up(f, (_) {}, (_) {});
      shim.down(f);
    });
    for (var i = 0; i < 20000; i++) {
      List<int> pkt;
      final mode = rnd.nextInt(4);
      if (mode == 0) {
        pkt = List.generate(rnd.nextInt(200), (_) => rnd.nextInt(256));
      } else {
        pkt = List.of(hex(seeds[rnd.nextInt(seeds.length)]));
        // портим: меняем байты, длины, обрезаем, дописываем
        for (var k = 0; k < 1 + rnd.nextInt(6); k++) {
          if (pkt.isEmpty) break;
          pkt[rnd.nextInt(pkt.length)] = rnd.nextInt(256);
        }
        if (mode == 2 && pkt.length > 4) pkt = pkt.sublist(0, rnd.nextInt(pkt.length));
        if (mode == 3) pkt.addAll(List.generate(rnd.nextInt(64), (_) => rnd.nextInt(256)));
      }
      // по одному пакету напрямую …
      shim.up(pkt, (_) {}, (_) {});
      shim.down(pkt);
      // … и кусками через нарезку потока
      var o = 0;
      while (o < pkt.length) {
        final n = 1 + rnd.nextInt(pkt.length - o);
        framer.add(pkt.sublist(o, o + n));
        o += n;
      }
    }
    expect(frames, greaterThan(0));
  });

  test('огромная заявленная длина не копит память бесконечно', () {
    final framer = StunFramer((_) {});
    // ChannelData с длиной 65535, затем много мусора
    framer.add([0x40, 0x00, 0xff, 0xff]);
    for (var i = 0; i < 200; i++) {
      framer.add(List.filled(1024, 7));
    }
  });
}
