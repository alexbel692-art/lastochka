// Функциональные тесты логики «ключ собеседника сменился» (SEC-01, SEC-07).
import 'package:flutter_test/flutter_test.dart';
import 'package:lastochka/system/trust_core.dart';

const me = '@me:x', bob = '@bob:x', eve = '@eve:x';

TrustResult run(
  Map<String, KeySnapshot> keys, {
  Map<String, String> pins = const {},
  Map<String, bool> pv = const {},
  Map<String, bool> changed = const {},
}) =>
    TrustCore.evaluate(pins: pins, pinVerified: pv, changed: changed, keys: keys, myId: me);

void main() {
  group('первая встреча', () {
    test('ключ запоминается, смены нет', () {
      final r = run({bob: const KeySnapshot('K1')});
      expect(r.pins[bob], 'K1');
      expect(r.changed, isEmpty);
      expect(r.dirty, isTrue);
    });
    test('неполный (устаревший) список не запоминается', () {
      final r = run({bob: const KeySnapshot('K1', outdated: true)});
      expect(r.pins, isEmpty);
      expect(r.dirty, isFalse);
    });
    test('подтверждённость запоминается', () {
      expect(run({bob: const KeySnapshot('K1', verified: true)}).pinVerified[bob], isTrue);
    });
  });

  group('смена ключа', () {
    test('другой ключ — смена, запомненный ключ не перезаписывается', () {
      final r = run({bob: const KeySnapshot('K2')}, pins: {bob: 'K1'});
      expect(r.changed.containsKey(bob), isTrue);
      expect(r.changed[bob], isFalse);
      expect(r.pins[bob], 'K1');
    });
    test('у подтверждённого собеседника — отмечается как подтверждённый', () {
      final r = run({bob: const KeySnapshot('K2')}, pins: {bob: 'K1'}, pv: {bob: true});
      expect(r.changed[bob], isTrue);
    });
    test('смена видна и в «устаревшем» списке', () {
      final r = run({bob: const KeySnapshot('K2', outdated: true)}, pins: {bob: 'K1'});
      expect(r.changed.containsKey(bob), isTrue);
    });
    test('тот же ключ — ничего не меняется', () {
      final r = run({bob: const KeySnapshot('K1')}, pins: {bob: 'K1'});
      expect(r.changed, isEmpty);
      expect(r.dirty, isFalse);
    });
    test('свой сброс — не смена собеседника, а ownReset', () {
      final r = run({me: const KeySnapshot('M2')}, pins: {me: 'M1'});
      expect(r.ownReset, isTrue);
      expect(r.changed, isEmpty);
      expect(r.pins[me], 'M2');
    });
  });

  group('SEC-07: ключ пропал', () {
    test('исчезнувший ключ — смена', () {
      final r = run({bob: const KeySnapshot(null)}, pins: {bob: 'K1'});
      expect(r.changed.containsKey(bob), isTrue);
      expect(r.pins[bob], 'K1');
    });
    test('пока ключ не загружен (устарел) — не судим', () {
      final r = run({bob: const KeySnapshot(null, outdated: true)}, pins: {bob: 'K1'});
      expect(r.changed, isEmpty);
    });
    test('принять смену без ключа нельзя', () {
      expect(TrustCore.canAccept(currentKey: null, shownKey: null, outdated: false), isFalse);
      expect(TrustCore.canAccept(currentKey: null, shownKey: 'K1', outdated: false), isFalse);
    });
    test('после пропажи появившийся чужой ключ — всё ещё смена, а не «первая встреча»', () {
      // ключ пропал → смена; принять нельзя → пин остаётся старым; появился K-eve → снова смена
      final r1 = run({bob: const KeySnapshot(null)}, pins: {bob: 'K1'});
      final r2 = run({bob: const KeySnapshot('KEVE')}, pins: r1.pins, changed: r1.changed);
      expect(r2.changed.containsKey(bob), isTrue);
      expect(r2.pins[bob], 'K1');
    });
    test('даже если «смену» как-то сняли, новый ключ сравнивается со старым пином', () {
      final r = run({bob: const KeySnapshot('KEVE')}, pins: {bob: 'K1'});
      expect(r.changed.containsKey(bob), isTrue);
    });
  });

  group('принятие смены', () {
    test('только показанный человеку ключ', () {
      expect(TrustCore.canAccept(currentKey: 'K2', shownKey: 'K2', outdated: false), isTrue);
      // SEC-02: без указания, какой ключ принимается, — нельзя
      expect(TrustCore.canAccept(currentKey: 'K2', shownKey: null, outdated: false), isFalse);
      expect(TrustCore.canAccept(currentKey: 'KEVE', shownKey: 'K2', outdated: false), isFalse);
    });
    test('не принимается, пока список ключей не загружен', () {
      expect(TrustCore.canAccept(currentKey: 'K2', shownKey: 'K2', outdated: true), isFalse);
    });
  });

  group('запрет отправки', () {
    test('защищённый чат с собеседником со сменившимся ключом — запрещено', () {
      expect(TrustCore.sendBlocked(encrypted: true, members: [me, bob], changed: {bob: false}), isTrue);
    });
    test('другой чат — можно', () {
      expect(TrustCore.sendBlocked(encrypted: true, members: [me, eve], changed: {bob: false}), isFalse);
    });
    test('смен нет — можно', () {
      expect(TrustCore.sendBlocked(encrypted: true, members: [me, bob], changed: {}), isFalse);
    });
    test('незашифрованный чат — проверка не применяется', () {
      expect(TrustCore.sendBlocked(encrypted: false, members: [me, bob], changed: {bob: true}), isFalse);
    });
  });
}
