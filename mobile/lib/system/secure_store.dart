// Небольшое зашифрованное хранилище (черновики, отложенные сообщения) — AES-256-GCM.
// Ключ выводится из ключа базы, который лежит в защищённом хранилище системы,
// поэтому без него эти данные из файлов настроек не прочитать.
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart' as h;
import 'package:cryptography/cryptography.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../matrix_client.dart';

class SecureStore {
  SecureStore._();
  static final instance = SecureStore._();

  final _aes = AesGcm.with256bits();
  SecretKey? _key;
  SharedPreferences? _p;

  Future<void> _init() async {
    _p ??= await SharedPreferences.getInstance();
    if (_key == null) {
      final s = deviceSecret;
      if (s == null) throw StateError('нет ключа устройства');
      _key = SecretKey(h.sha256.convert(utf8.encode('lastochka-store|$s')).bytes);
    }
  }

  Future<Object?> read(String name) async {
    try {
      await _init();
      final raw = _p!.getString('box.$name');
      if (raw == null) return null;
      final b = base64.decode(raw);
      final box = SecretBox(b.sublist(12, b.length - 16), nonce: b.sublist(0, 12), mac: Mac(b.sublist(b.length - 16)));
      final clear = await _aes.decrypt(box, secretKey: _key!, aad: utf8.encode(name));
      return jsonDecode(utf8.decode(clear));
    } catch (_) {
      return null;
    }
  }

  Future<void> write(String name, Object? value) async {
    await _init();
    if (value == null) {
      await _p!.remove('box.$name');
      return;
    }
    final rnd = Random.secure();
    final nonce = List<int>.generate(12, (_) => rnd.nextInt(256));
    final box = await _aes.encrypt(utf8.encode(jsonEncode(value)), secretKey: _key!, nonce: nonce, aad: utf8.encode(name));
    await _p!.setString('box.$name', base64.encode([...box.nonce, ...box.cipherText, ...box.mac.bytes]));
  }
}
