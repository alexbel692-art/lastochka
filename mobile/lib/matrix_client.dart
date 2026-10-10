// Клиент Matrix: шифрование vodozemac (Rust) и база данных, зашифрованная SQLCipher
// (одна и та же на Android, iPhone, Windows и macOS).
// Ключ базы хранится в защищённом хранилище системы: Android Keystore, iOS/macOS Keychain,
// Windows — шифрование учётной записи (DPAPI).
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_vodozemac/flutter_vodozemac.dart' as vod;
import 'package:matrix/encryption/utils/key_verification.dart';
import 'package:matrix/matrix.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'system/pinning.dart';

const _secure = FlutterSecureStorage(
  // на macOS без платной подписи Apple «новая» связка ключей недоступна — используем обычную
  mOptions: MacOsOptions(usesDataProtectionKeychain: false),
);
const _dbKeyName = 'lastochka.db_key';
const clientName = 'lastochka';

/// Секрет устройства (ключ базы) — из него выводится ключ для черновиков и отложенных сообщений.
String? deviceSecret;

Future<Directory> _dataDir() async {
  final d = Platform.isMacOS || Platform.isIOS ? await getLibraryDirectory() : await getApplicationSupportDirectory();
  return d.create(recursive: true);
}

/// Ключ базы. Если системное хранилище недоступно (редко, например macOS без подписи),
/// ключ лежит в файле в папке приложения, доступной только этому пользователю.
/// Новый ключ создаётся, только если базы ещё нет — иначе можно потерять ключи шифрования.
Future<String> _databaseKey(bool dbExists) async {
  final fallback = File(p.join((await _dataDir()).path, '.$clientName.key'));
  String? key;
  Object? readError;
  for (var i = 0; i < 3 && key == null; i++) {
    try {
      key = await _secure.read(key: _dbKeyName);
      readError = null;
      break;
    } catch (e) {
      readError = e;
      await Future.delayed(const Duration(milliseconds: 400));
    }
  }
  if (key == null && await fallback.exists()) key = (await fallback.readAsString()).trim();
  if (key != null && key.isNotEmpty) return key;
  if (dbExists && readError != null) {
    throw StateError('Нет доступа к ключу базы в защищённом хранилище системы. Разрешите Ласточке доступ к связке ключей и перезапустите её.');
  }
  final rnd = Random.secure();
  key = base64Url.encode(List<int>.generate(32, (_) => rnd.nextInt(256))).replaceAll('=', '');
  try {
    await _secure.write(key: _dbKeyName, value: key);
  } catch (e) {
    await fallback.writeAsString(key, flush: true);
  }
  return key;
}

Future<DatabaseApi> _openDatabase() async {
  final path = p.join((await _dataDir()).path, '$clientName.sqlite');
  final cache = await Directory(p.join((await getTemporaryDirectory()).path, '${clientName}_files')).create(recursive: true);
  final factory = createDatabaseFactoryFfi();
  databaseFactory = factory;
  final dbFile = File(path);
  final cipher = await _databaseKey(await dbFile.exists());
  deviceSecret = cipher;

  Future<Database> open() async {
    final helper = SQfLiteEncryptionHelper(factory: factory, path: path, cipher: cipher);
    await helper.ensureDatabaseFileEncrypted();
    return factory.openDatabase(
      path,
      options: OpenDatabaseOptions(version: 1, onConfigure: (db) => helper.applyPragmaKey(db)),
    );
  }

  Future<DatabaseApi> init() async => MatrixSdkDatabase.init(
        clientName,
        database: await open(),
        maxFileSize: 10 * 1000 * 1000,
        fileStorageLocation: cache.uri,
        deleteFilesAfterDuration: Duration(days: await fileKeepDays()),
      );

  // отметка «база создана этой версией»: только старую базу (Android до 0.4) можно пересоздать
  final marker = File('$path.v2');
  try {
    final db = await init();
    if (!await marker.exists()) await marker.writeAsString('1');
    return db;
  } catch (e) {
    if (await marker.exists()) rethrow; // своя база не открылась — не удаляем, чтобы не потерять ключи
    Logs().w('[Ласточка] база от старой версии не открылась, создаём новую', e);
    if (await dbFile.exists()) await dbFile.delete();
    final db = await init();
    await marker.writeAsString('1');
    return db;
  }
}

/// Сколько дней хранить загруженные файлы (настройка «Хранилище»).
Future<int> fileKeepDays() async => (await SharedPreferences.getInstance()).getInt('storage.days') ?? 30;

Future<int> _sizeOf(FileSystemEntity e) async {
  try {
    if (e is File) return await e.length();
    if (e is Directory && await e.exists()) {
      var n = 0;
      await for (final f in e.list(recursive: true, followLinks: false)) {
        if (f is File) n += await f.length().catchError((_) => 0);
      }
      return n;
    }
  } catch (_) {}
  return 0;
}

/// Сколько места занимает Ласточка: база (переписка и ключи), загруженные файлы, временные файлы.
Future<({int db, int files, int temp})> storageUsage() async {
  final dir = await _dataDir();
  final path = p.join(dir.path, '$clientName.sqlite');
  var db = 0;
  for (final f in [path, '$path-wal', '$path-shm']) {
    db += await _sizeOf(File(f));
  }
  final tmp = await getTemporaryDirectory();
  final files = await _sizeOf(Directory(p.join(tmp.path, '${clientName}_files')));
  final temp = await _sizeOf(Directory(p.join(tmp.path, 'lastochka-update')));
  return (db: db, files: files, temp: temp);
}

/// Очистить загруженные файлы (картинки, видео, голосовые): при необходимости они скачаются заново.
Future<void> clearFileCache() async {
  final tmp = await getTemporaryDirectory();
  for (final d in [Directory(p.join(tmp.path, '${clientName}_files')), Directory(p.join(tmp.path, 'lastochka-update'))]) {
    try {
      if (!await d.exists()) continue;
      await for (final f in d.list()) {
        try {
          await f.delete(recursive: true);
        } catch (_) {}
      }
    } catch (_) {}
  }
}

/// Стереть всё хранилище Ласточки на устройстве: базу (с журналами), ключ базы, кэш файлов.
Future<void> wipeLocalStorage() async {
  final dir = await _dataDir();
  final path = p.join(dir.path, '$clientName.sqlite');
  for (final f in [path, '$path-wal', '$path-shm', '$path-journal', '$path.v2', p.join(dir.path, '.$clientName.key')]) {
    try {
      final file = File(f);
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }
  try {
    await _secure.delete(key: _dbKeyName);
  } catch (_) {}
  try {
    final cache = Directory(p.join((await getTemporaryDirectory()).path, '${clientName}_files'));
    if (await cache.exists()) await cache.delete(recursive: true);
  } catch (_) {}
  deviceSecret = null;
}

Future<Client> createClient() async {
  await vod.init();
  final client = Client(
    clientName,
    httpClient: CertPinning.instance.httpClient(),
    database: await _openDatabase(),
    verificationMethods: {KeyVerificationMethod.emoji, KeyVerificationMethod.numbers},
    importantStateEvents: {'im.ponies.room_emotes'},
    supportedLoginTypes: {AuthenticationTypes.password},
    // ключи сообщений получают только устройства, подтверждённые их владельцем (подписанные).
    // Вошедший по украденному паролю без ключа восстановления и без подтверждения
    // с другого устройства ключей не получит. Ласточка требует подтверждать каждый вход,
    // поэтому у своих в группах «не удалось расшифровать» не возникает.
    shareKeysWith: ShareKeysWith.crossVerifiedIfEnabled,
    nativeImplementations: NativeImplementationsIsolate(compute, vodozemacInit: () => vod.init()),
    logLevel: kReleaseMode ? Level.warning : Level.info,
  );
  await client.init(waitForFirstSync: false);
  return client;
}

/// Название устройства в списке сеансов.
String deviceLabel() {
  final os = Platform.isIOS
      ? 'iPhone'
      : Platform.isAndroid
          ? 'Android'
          : Platform.isMacOS
              ? 'Mac'
              : Platform.isWindows
                  ? 'Windows'
                  : 'Linux';
  return 'Ласточка ($os)';
}
