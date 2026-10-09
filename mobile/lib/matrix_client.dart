// Клиент Matrix: шифрование vodozemac (Rust) и база данных, зашифрованная SQLCipher.
// Ключ базы хранится в защищённом хранилище системы (Android Keystore / iOS Keychain).
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_vodozemac/flutter_vodozemac.dart' as vod;
import 'package:matrix/encryption/utils/key_verification.dart';
import 'package:matrix/matrix.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_sqlcipher/sqflite.dart' as sqlcipher;

const _secure = FlutterSecureStorage(
  aOptions: AndroidOptions(encryptedSharedPreferences: true),
);
const _dbKeyName = 'lastochka.db_key';
const clientName = 'lastochka';

Future<String> _databaseKey() async {
  var key = await _secure.read(key: _dbKeyName);
  if (key == null) {
    final rnd = Random.secure();
    key = base64Url.encode(List<int>.generate(32, (_) => rnd.nextInt(256)));
    await _secure.write(key: _dbKeyName, value: key);
  }
  return key;
}

Future<DatabaseApi> _openDatabase() async {
  final dir = await getApplicationSupportDirectory();
  final path = p.join(dir.path, '$clientName.sqlite');
  final cache = await getTemporaryDirectory();
  return MatrixSdkDatabase.init(
    clientName,
    database: await sqlcipher.openDatabase(path, password: await _databaseKey()),
    maxFileSize: 10 * 1000 * 1000,
    fileStorageLocation: cache.uri,
    deleteFilesAfterDuration: const Duration(days: 30),
  );
}

Future<Client> createClient() async {
  await vod.init();
  final client = Client(
    clientName,
    database: await _openDatabase(),
    verificationMethods: {KeyVerificationMethod.emoji, KeyVerificationMethod.numbers},
    importantStateEvents: {'im.ponies.room_emotes'},
    supportedLoginTypes: {AuthenticationTypes.password},
    nativeImplementations: NativeImplementationsIsolate(compute, vodozemacInit: () => vod.init()),
    logLevel: kReleaseMode ? Level.warning : Level.info,
  );
  await client.init(waitForFirstSync: false);
  return client;
}
