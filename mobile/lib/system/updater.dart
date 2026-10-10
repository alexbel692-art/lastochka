// Автообновление Ласточки через GitHub Releases (Windows, macOS, Android).
// Ставится только файл, подписанный ключом разработчика (Ed25519) — тем же, что у прежней
// настольной версии. Подменённый или повреждённый файл не пройдёт проверку подписи и SHA-256.
import 'dart:async';
import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:crypto/crypto.dart' as hash;
import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'package:shared_preferences/shared_preferences.dart';

import 'desktop.dart';
import 'pinning.dart';
import 'notify.dart';

const appVersion = String.fromEnvironment('APP_VERSION', defaultValue: '0.0.0');
const _repo = 'alexbel692-art/lastochka';
// публичный ключ Ed25519 (последние 32 байта SPKI «MCowBQYDK2VwAyEA…»)
const _publicKeyB64 = 'MCowBQYDK2VwAyEAt/kw3nU6I8XI9xvrdyCFpvd+w8gjfAALDSDl5BRRQgE=';

int cmpVer(String a, String b) {
  List<int> parse(String s) => s.split(RegExp(r'[.\-+]')).map((x) => int.tryParse(x) ?? 0).toList();
  final pa = parse(a), pb = parse(b);
  for (var i = 0; i < (pa.length > pb.length ? pa.length : pb.length); i++) {
    final d = (i < pa.length ? pa[i] : 0) - (i < pb.length ? pb[i] : 0);
    if (d != 0) return d;
  }
  return 0;
}

/// Проверка подписи файла обновления: Ed25519 над «lastochka|версия|файл|sha256».
Future<bool> verifyUpdateSignature(Map<String, dynamic> s) async {
  try {
    final msg = utf8.encode('lastochka|${s['version']}|${s['file']}|${s['sha256']}');
    final spki = base64.decode(_publicKeyB64);
    final pub = SimplePublicKey(spki.sublist(spki.length - 32), type: KeyPairType.ed25519);
    return await Ed25519().verify(msg, signature: Signature(base64.decode('${s['sig']}'), publicKey: pub));
  } catch (_) {
    return false;
  }
}

class UpdateInfo {
  final String version, notes, fileName, fileUrl, sigUrl;
  final int size;
  UpdateInfo(this.version, this.notes, this.fileName, this.fileUrl, this.sigUrl, this.size);
}

class Updater {
  Updater._();
  static final instance = Updater._();

  // GitHub — с тем же расширенным набором корневых сертификатов (на старых Android иначе
  // «unable to get local issuer certificate»); подлинность файла всё равно проверяет наша подпись
  final _http = IOClient(HttpClient(context: CertPinning.trustContext)..connectionTimeout = const Duration(seconds: 30));

  final available = ValueNotifier<UpdateInfo?>(null);
  final progress = ValueNotifier<double?>(null); // 0..1 во время скачивания
  final error = ValueNotifier<String?>(null);
  Timer? _timer;

  bool get supported => Platform.isWindows || Platform.isMacOS || Platform.isAndroid;

  void start() {
    if (!supported || appVersion == '0.0.0') return;
    Future.delayed(const Duration(seconds: 20), check);
    _timer ??= Timer.periodic(const Duration(hours: 6), (_) => check());
  }

  /// Защита от отката: если на устройстве вдруг оказалась версия старее, чем уже стояла
  /// (её могли поставить, чтобы вернуть исправленную уязвимость), — предупреждаем.
  Future<void> checkDowngrade() async {
    if (appVersion == '0.0.0') return;
    final prefs = await SharedPreferences.getInstance();
    final highest = prefs.getString('update.highest');
    if (highest != null && cmpVer(appVersion, highest) < 0) {
      await showSecurityNotification('Установлена старая версия Ласточки',
          'Сейчас $appVersion, а раньше стояла $highest. Если вы этого не делали — установите последнюю версию с официальной страницы.');
      return;
    }
    await prefs.setString('update.highest', appVersion);
  }

  RegExp? get _assetPattern {
    if (Platform.isWindows) return RegExp(r'^Lastochka-Setup-.*\.exe$', caseSensitive: false);
    if (Platform.isMacOS) return RegExp(r'-arm64\.dmg$', caseSensitive: false); // сборка универсальная
    if (Platform.isAndroid) {
      // APK только под процессор этого телефона — в 3 раза меньше общего
      return switch (Abi.current()) {
        Abi.androidArm64 => RegExp(r'-Android-arm64\.apk$', caseSensitive: false),
        Abi.androidArm => RegExp(r'-Android-arm\.apk$', caseSensitive: false),
        _ => RegExp(r'-Android\.apk$', caseSensitive: false),
      };
    }
    return null;
  }

  /// Проверить, есть ли новая версия. Возвращает true, если есть.
  Future<bool> check() async {
    final re = _assetPattern;
    if (re == null) return false;
    try {
      final r = await _http.get(Uri.parse('https://api.github.com/repos/$_repo/releases/latest'),
          headers: {'accept': 'application/vnd.github+json', 'user-agent': 'Lastochka-Updater'});
      if (r.statusCode != 200) return false;
      final rel = jsonDecode(r.body) as Map<String, dynamic>;
      final version = '${rel['tag_name'] ?? ''}'.replaceFirst(RegExp('^v'), '');
      if (version.isEmpty || cmpVer(version, appVersion) <= 0) {
        available.value = null;
        return false;
      }
      final assets = (rel['assets'] as List? ?? []).cast<Map<String, dynamic>>();
      final universal = RegExp(r'-Android\.apk$', caseSensitive: false);
      final file = assets.where((a) => re.hasMatch('${a['name']}')).firstOrNull ??
          (Platform.isAndroid ? assets.where((a) => universal.hasMatch('${a['name']}')).firstOrNull : null);
      final sig = file == null ? null : assets.where((a) => a['name'] == '${file['name']}.sig').firstOrNull;
      if (file == null || sig == null) return false;
      available.value = UpdateInfo(version, '${rel['body'] ?? ''}', '${file['name']}', '${file['browser_download_url']}',
          '${sig['browser_download_url']}', (file['size'] as num?)?.toInt() ?? 0);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Скачать, проверить подпись и установить.
  Future<void> install() async {
    final u = available.value;
    if (u == null || progress.value != null) return;
    error.value = null;
    progress.value = 0;
    try {
      // 1. подпись: какой файл, какая версия, какой SHA-256
      final sr = await _http.get(Uri.parse(u.sigUrl), headers: {'user-agent': 'Lastochka-Updater'});
      if (sr.statusCode != 200) throw 'Не удалось скачать подпись';
      final s = jsonDecode(sr.body) as Map<String, dynamic>;
      if (!await verifyUpdateSignature(s)) throw 'Подпись обновления неверна — установка отменена';
      if (s['file'] != u.fileName || s['version'] != u.version) throw 'Подпись относится к другому файлу — установка отменена';
      if (cmpVer('${s['version']}', appVersion) <= 0) throw 'Подписанная версия не новее текущей';

      // 2. файл: качаем и считаем SHA-256 по ходу
      final dir = await Directory(p.join((await getTemporaryDirectory()).path, 'lastochka-update')).create(recursive: true);
      final target = File(p.join(dir.path, u.fileName));
      final req = http.Request('GET', Uri.parse(u.fileUrl))..headers['user-agent'] = 'Lastochka-Updater';
      final resp = await _http.send(req);
      if (resp.statusCode != 200) throw 'Не удалось скачать обновление (${resp.statusCode})';
      final total = resp.contentLength ?? u.size;
      final out = target.openWrite();
      final digestSink = _DigestSink();
      final sha = hash.sha256.startChunkedConversion(digestSink);
      var got = 0;
      await for (final chunk in resp.stream) {
        out.add(chunk);
        sha.add(chunk);
        got += chunk.length;
        if (total > 0) progress.value = got / total;
      }
      await out.close();
      sha.close();
      if (digestSink.value.toString() != s['sha256']) {
        try {
          await target.delete();
        } catch (_) {}
        throw 'Файл обновления повреждён или подменён — установка отменена';
      }

      // 3. установка
      if (Platform.isWindows) {
        // тихая установка поверх; после неё Ласточка запустится сама.
        // Windows попросит права администратора (установка для всех пользователей)
        await Process.start(target.path, ['/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/CLOSEAPPLICATIONS'], mode: ProcessStartMode.detached);
        await Future.delayed(const Duration(milliseconds: 600));
        await quitApp();
      } else if (Platform.isMacOS) {
        await Process.run('open', [target.path]); // откроется образ — перетащите Ласточку в «Программы»
      } else if (Platform.isAndroid) {
        final r = await OpenFilex.open(target.path, type: 'application/vnd.android.package-archive');
        if (r.type != ResultType.done) throw 'Разрешите Ласточке устанавливать приложения: Настройки → Приложения → Ласточка → Установка неизвестных приложений';
      }
    } catch (e) {
      error.value = '$e';
    } finally {
      progress.value = null;
    }
  }
}

class _DigestSink implements Sink<hash.Digest> {
  hash.Digest? _d;
  hash.Digest get value => _d!;
  @override
  void add(hash.Digest data) => _d = data;
  @override
  void close() {}
}
