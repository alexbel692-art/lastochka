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
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'package:shared_preferences/shared_preferences.dart';

import 'pinning.dart';
import 'notify.dart';
import 'diag.dart';
import 'perf.dart' show remoteSession;
import '../calls/voip.dart' show callActive;

const appVersion = String.fromEnvironment('APP_VERSION', defaultValue: '0.0.0');
const _maxUpdate = 400 * 1024 * 1024;
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
  /// Нашлась версия, о которой ещё не сообщали (раз за запуск на каждую версию).
  void Function(UpdateInfo u)? onNewVersion;
  final _announced = <String>{};
  final progress = ValueNotifier<double?>(null); // 0..1 во время скачивания
  final error = ValueNotifier<String?>(null);
  Timer? _timer;

  bool get supported => Platform.isWindows || Platform.isMacOS || Platform.isAndroid;

  DateTime? _lastCheck;

  final _started = DateTime.now();

  /// Скачано и проверено — ждёт установки (версия).
  final ready = ValueNotifier<String?>(null);
  File? _readyFile;
  bool _busy = false;
  bool _applying = false;

  /// Обновлять самостоятельно (настройка, по умолчанию включено).
  static Future<bool> autoEnabled() async {
    try {
      return (await SharedPreferences.getInstance()).getBool('update.auto') ?? true;
    } catch (_) {
      return true;
    }
  }

  void start() {
    if (!supported || appVersion == '0.0.0') return;
    onInstallStatus = _onAndroidStatus;
    // при запуске — сразу (через пару секунд, чтобы не мешать открытию чатов)
    Future.delayed(const Duration(seconds: 3), _auto);
    // проверка раз в час: новая версия не пройдёт незамеченной, даже если Ласточку не закрывают
    _timer ??= Timer.periodic(const Duration(hours: 1), (_) => _auto());
    // вернулись в Ласточку, а проверяли больше часа назад — проверим снова;
    // свернули — самое время поставить уже скачанное обновление
    visibility.addListener(() {
      final l = _lastCheck;
      if (appVisible && (l == null || DateTime.now().difference(l).inMinutes >= 60)) _auto();
      if (!appVisible) _applyIfQuiet();
    });
    callActive.addListener(_applyIfQuiet);
  }

  /// Проверить, скачать и (когда удобно) поставить — без участия человека.
  Future<void> _auto() async {
    if (_busy) return;
    _busy = true; // сразу — чтобы два одновременных вызова не скачивали одно и то же
    try {
      if (!await check()) return;
      if (!await autoEnabled()) return; // ручной режим: только полоска «Доступна новая версия»
    } finally {
      _busy = false;
    }
    final u = available.value;
    if (u == null || ready.value == u.version) return _applyIfQuiet();
    if (_busy) return;
    _busy = true;
    try {
      _readyFile = await _download(u);
      ready.value = u.version;
      Diag.add('Обновление ${u.version} скачано и проверено');
    } catch (e, st) {
      Diag.err('Автообновление', e, st);
    } finally {
      _busy = false;
    }
    await _applyIfQuiet();
  }

  /// Поставить скачанное обновление, если сейчас это никому не помешает:
  /// не идёт звонок; компьютер — сразу после запуска или когда окно свёрнуто;
  /// телефон — когда Ласточка свёрнута (Android закрывает приложение на время установки).
  Future<void> _applyIfQuiet() async {
    final f = _readyFile;
    if (f == null || _applying || callActive.value || !await autoEnabled()) return;
    // одна автоматическая попытка на версию раз в 12 часов: если Windows спросила права администратора и человек
    // отказался или Android ждёт подтверждения, не спрашиваем снова при каждом сворачивании
    final prefs = await SharedPreferences.getInstance();
    final tried = prefs.getString('update.tried') ?? '';
    final triedAt = DateTime.fromMillisecondsSinceEpoch(prefs.getInt('update.triedAt') ?? 0);
    if (tried == ready.value && DateTime.now().difference(triedAt).inHours < 12) return;
    final justStarted = DateTime.now().difference(_started).inMinutes < 3;
    if (Platform.isWindows) {
      if (remoteSession) return; // сервер RDP: у пользователей нет прав администратора — обновляет админ
      if (!justStarted && appVisible) return;
    } else if (Platform.isMacOS) {
      // песочница macOS не даёт программе заменить себя — открываем готовый образ один раз
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getString('update.opened') == ready.value) return;
      await prefs.setString('update.opened', ready.value ?? '');
    } else if (Platform.isAndroid) {
      if (appVisible) return;
    }
    _applying = true;
    await prefs.setString('update.tried', ready.value ?? '');
    await prefs.setInt('update.triedAt', DateTime.now().millisecondsSinceEpoch);
    try {
      await _apply(f, interactive: false);
    } catch (e, st) {
      Diag.err('Автоустановка обновления', e, st);
    } finally {
      // на Android установка идёт дальше в системе — ответ придёт в _onAndroidStatus
      if (!Platform.isAndroid) _applying = false;
    }
  }

  void _onAndroidStatus(String st) {
    Diag.add('Установка обновления: $st');
    if (st == 'pending') {
      // система просит подтвердить — окно «Обновить» откроется, как только Ласточку откроют
      if (!appVisible) showSecurityNotification('Обновление Ласточки готово', 'Откройте Ласточку и нажмите «Обновить» — это займёт несколько секунд');
      _applying = false;
    } else if (st.startsWith('fail')) {
      _applying = false;
      error.value = 'Не удалось установить обновление (${st.replaceFirst('fail:', '')})';
    }
  }

  /// Прошлая установка обновления на Windows не удалась (версия не сменилась) — причину из журнала
  /// установщика — в отчёт и сообщение человеку. Вызывается при запуске.
  Future<String?> checkFailedInstall() async {
    if (!Platform.isWindows || appVersion == '0.0.0') return null;
    final prefs = await SharedPreferences.getInstance();
    final want = prefs.getString('update.pendingVer');
    final log = prefs.getString('update.pendingLog');
    if (want == null || want.isEmpty) return null;
    await prefs.remove('update.pendingVer');
    if (cmpVer(appVersion, want) >= 0) return null; // обновилось
    var why = 'установщик не завершил работу';
    try {
      if (log != null && await File(log).exists()) {
        final lines = await File(log).readAsLines();
        final bad = lines
            .where((l) => RegExp(r'error|failed|abort|cannot|denied|in use|занят|ошибк|Exception|code \d+', caseSensitive: false).hasMatch(l))
            .toList();
        Diag.add('Журнал установщика ($want): ${(bad.isEmpty ? lines.reversed.take(15).toList().reversed : bad.take(15)).join(' | ')}');
        if (lines.any((l) => l.contains('Need to restart Windows') || l.contains('in use'))) {
          why = 'файлы Ласточки заняты (возможно, она открыта у других пользователей этого компьютера)';
        } else if (lines.any((l) => l.contains('elevat') || l.contains('privileges'))) {
          why = 'Windows не дала прав администратора';
        } else if (bad.isNotEmpty) {
          why = bad.last.length > 160 ? bad.last.substring(bad.last.length - 160) : bad.last;
        }
      } else {
        why = 'установщик не запустился — вероятно, Windows не дала прав администратора';
      }
    } catch (_) {}
    Diag.add('Обновление до $want не установилось: $why');
    return 'Обновление до $want не установилось: $why. Нажмите «Обновить» ещё раз — появится окно установщика.';
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

  /// Android: под какой процессор брать APK. Смотрим, что умеет телефон, а не в каком режиме
  /// запущена Ласточка: если когда-то поставили 32-битный APK на 64-битный телефон, обновление
  /// переведёт её на 64-битную версию (новые Android иначе пишут «не совместимо с последней версией»).
  static Future<String> androidAbi() async {
    try {
      final l = await const MethodChannel('lastochka/system').invokeListMethod<String>('abis');
      if (l != null && l.contains('arm64-v8a')) return 'arm64';
      if (l != null && l.contains('armeabi-v7a')) return 'arm';
    } catch (_) {}
    return switch (Abi.current()) { Abi.androidArm64 => 'arm64', Abi.androidArm => 'arm', _ => 'universal' };
  }

  /// Запущена 32-битная версия на 64-битном телефоне — нужно переставить, даже если номер версии тот же.
  Future<bool> wrongAbi() async => Platform.isAndroid && Abi.current() == Abi.androidArm && await androidAbi() == 'arm64';

  Future<RegExp?> _assetPattern() async {
    if (Platform.isWindows) return RegExp(r'^Lastochka-Setup-.*\.exe$', caseSensitive: false);
    if (Platform.isMacOS) return RegExp(r'-arm64\.dmg$', caseSensitive: false); // сборка универсальная
    if (Platform.isAndroid) {
      // APK только под процессор этого телефона — в 3 раза меньше общего
      return switch (await androidAbi()) {
        'arm64' => RegExp(r'-Android-arm64\.apk$', caseSensitive: false),
        'arm' => RegExp(r'-Android-arm\.apk$', caseSensitive: false),
        _ => RegExp(r'-Android\.apk$', caseSensitive: false),
      };
    }
    return null;
  }

  /// Проверить, есть ли новая версия. Возвращает true, если есть.
  Future<bool> check() async {
    _lastCheck = DateTime.now();
    final re = await _assetPattern();
    if (re == null) return false;
    final switchAbi = await wrongAbi();
    try {
      // тестовые версии (бета): берём самую новую из последних выпусков, включая предварительные
      final beta = (await SharedPreferences.getInstance()).getBool('update.beta') ?? false;
      final r = await _http.get(Uri.parse('https://api.github.com/repos/$_repo/releases${beta ? '?per_page=15' : '/latest'}'),
          headers: {'accept': 'application/vnd.github+json', 'user-agent': 'Lastochka-Updater'});
      if (r.statusCode != 200) return false;
      final Map<String, dynamic> rel;
      if (beta) {
        final all = (jsonDecode(r.body) as List).cast<Map<String, dynamic>>().where((x) => x['draft'] != true && RegExp(r'^v\d+\.\d+\.\d+$').hasMatch('${x['tag_name']}')).toList();
        if (all.isEmpty) return false;
        all.sort((a, b) => cmpVer('${b['tag_name']}'.substring(1), '${a['tag_name']}'.substring(1)));
        rel = all.first;
      } else {
        rel = jsonDecode(r.body) as Map<String, dynamic>;
      }
      final version = '${rel['tag_name'] ?? ''}'.replaceFirst(RegExp('^v'), '');
      if (version.isEmpty || cmpVer(version, appVersion) < 0 || (cmpVer(version, appVersion) == 0 && !switchAbi)) {
        available.value = null;
        return false;
      }
      final assets = (rel['assets'] as List? ?? []).cast<Map<String, dynamic>>();
      final universal = RegExp(r'-Android\.apk$', caseSensitive: false);
      final file = assets.where((a) => re.hasMatch('${a['name']}')).firstOrNull ??
          (Platform.isAndroid ? assets.where((a) => universal.hasMatch('${a['name']}')).firstOrNull : null);
      final sig = file == null ? null : assets.where((a) => a['name'] == '${file['name']}.sig').firstOrNull;
      if (file == null || sig == null) return false;
      if (switchAbi) Diag.add('Стоит 32-битная версия на 64-битном телефоне — предлагаем переустановку');
      final isNew = !_announced.contains(version);
      _announced.add(version);
      available.value = UpdateInfo(version, switchAbi && cmpVer(version, appVersion) == 0 ? 'Версия для вашего процессора — уберёт предупреждение о совместимости' : '${rel['body'] ?? ''}', '${file['name']}', '${file['browser_download_url']}',
          '${sig['browser_download_url']}', (file['size'] as num?)?.toInt() ?? 0);
      if (isNew && available.value != null) onNewVersion?.call(available.value!);
      return true;
    } catch (e) {
      Diag.err('Проверка обновлений', e);
      return false;
    }
  }

  /// Скачать, проверить подпись и установить (нажали «Обновить»).
  Future<void> install() async {
    if (progress.value != null || _busy) return;
    // сведения могли устареть (проверка раз в 6 часов) — уточняем: вдруг уже вышла версия новее
    await check();
    final u = available.value;
    if (u == null) return;
    error.value = null;
    _busy = true;
    try {
      final f = ready.value == u.version && _readyFile != null ? _readyFile! : await _download(u);
      _readyFile = f;
      ready.value = u.version;
      _applying = true;
      await _apply(f, interactive: true);
    } catch (e, st) {
      Diag.err('Установка обновления', e, st);
      error.value = '$e';
    } finally {
      _busy = false;
      if (!Platform.isAndroid) _applying = false;
    }
  }

  Map<String, dynamic>? _sig;

  /// Скачать файл обновления и проверить подпись разработчика и SHA-256. Уже скачанный — только перепроверить.
  Future<File> _download(UpdateInfo u) async {
    progress.value = 0;
    try {
      // 1. подпись: какой файл, какая версия, какой SHA-256
      final sr = await _http.get(Uri.parse(u.sigUrl), headers: {'user-agent': 'Lastochka-Updater'});
      if (sr.statusCode != 200) throw 'Не удалось скачать подпись';
      final s = jsonDecode(sr.body) as Map<String, dynamic>;
      if (!await verifyUpdateSignature(s)) throw 'Подпись обновления неверна — установка отменена';
      if (s['file'] != u.fileName || s['version'] != u.version) throw 'Подпись относится к другому файлу — установка отменена';
      final c = cmpVer('${s['version']}', appVersion);
      // та же версия допускается только для перехода 32-бит → 64-бит на 64-битном телефоне
      final sameForAbi = c == 0 && await wrongAbi() && RegExp(r'-Android-arm64\.apk$').hasMatch(u.fileName);
      if (c < 0 || (c == 0 && !sameForAbi)) throw 'Подписанная версия не новее текущей';
      _sig = s;

      final dir = await Directory(p.join((await getTemporaryDirectory()).path, 'lastochka-update')).create(recursive: true);
      final target = File(p.join(dir.path, u.fileName));
      // уже скачан раньше (например, до перезапуска) — не качаем заново, если совпадает SHA-256
      if (await target.exists()) {
        final d = await hash.sha256.bind(target.openRead()).first;
        if (d.toString() == s['sha256']) return target;
      }
      // старые скачанные версии больше не нужны
      try {
        await for (final f in dir.list()) {
          if (f.path != target.path) await f.delete(recursive: true);
        }
      } catch (_) {}

      // 2. файл: качаем и считаем SHA-256 по ходу
      final req = http.Request('GET', Uri.parse(u.fileUrl))..headers['user-agent'] = 'Lastochka-Updater';
      final resp = await _http.send(req);
      if (resp.statusCode != 200) throw 'Не удалось скачать обновление (${resp.statusCode})';
      final total = resp.contentLength ?? u.size;
      // предел по размеру: не больше заявленного в выпуске (с запасом) и не больше 400 МБ —
      // подменённый или бесконечный ответ не забьёт диск
      final limit = u.size > 0 ? (u.size + 1024 * 1024 < _maxUpdate ? u.size + 1024 * 1024 : _maxUpdate) : _maxUpdate;
      if (resp.contentLength != null && resp.contentLength! > limit) throw 'Файл обновления больше ожидаемого — загрузка отменена';
      final out = target.openWrite();
      final digestSink = _DigestSink();
      final sha = hash.sha256.startChunkedConversion(digestSink);
      var got = 0;
      await for (final chunk in resp.stream) {
        got += chunk.length;
        if (got > limit) {
          await out.close();
          try {
            await target.delete();
          } catch (_) {}
          throw 'Файл обновления больше ожидаемого — загрузка отменена';
        }
        out.add(chunk);
        sha.add(chunk);
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
      return target;
    } finally {
      progress.value = null;
    }
  }

  /// Установить проверенный файл.
  Future<void> _apply(File target, {required bool interactive}) async {
    // перед установкой ещё раз сверяем файл с подписью (он лежал на диске)
    final s = _sig;
    if (s == null || (await hash.sha256.bind(target.openRead()).first).toString() != s['sha256']) {
      _readyFile = null;
      ready.value = null;
      throw 'Файл обновления изменился — скачаем заново';
    }
    if (Platform.isWindows) {
      // установка поверх; после неё Ласточка запустится сама. Windows попросит права администратора
      // (установка для всех пользователей). Ласточку закрывает сам установщик — после того как Windows
      // дала права; если в правах отказали, установщик просто выходит, а Ласточка продолжает работать.
      // По нажатию «Обновить» — с окном хода установки и сообщениями об ошибках (раньше всё шло невидимо,
      // и при сбое казалось, что «ничего не происходит»); автоматически — без окон.
      // Журнал установщика сохраняется: если обновление не встанет, причина попадёт в отчёт.
      final log = p.join(Directory.systemTemp.path, 'lastochka-update.log');
      Diag.add('Устанавливаем обновление ${ready.value}${interactive ? ' (с окном установщика)' : ''}');
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('update.pendingVer', ready.value ?? '');
      await prefs.setString('update.pendingLog', log);
      await Process.start(
          target.path,
          [
            interactive ? '/SILENT' : '/VERYSILENT',
            if (!interactive) '/SUPPRESSMSGBOXES',
            '/NORESTART',
            '/CLOSEAPPLICATIONS',
            '/FORCECLOSEAPPLICATIONS',
            '/LOG=$log',
          ],
          mode: ProcessStartMode.detached);
    } else if (Platform.isMacOS) {
      await Process.run('open', [target.path]); // откроется образ — перетащите Ласточку в «Программы»
    } else if (Platform.isAndroid) {
      // системный установщик: на Android 12+ обновляет без вопросов, иначе покажет «Обновить»
      String r;
      try {
        r = await const MethodChannel('lastochka/system').invokeMethod<String>('installApk', target.path) ?? 'error';
      } catch (e) {
        r = 'error:$e';
      }
      if (r != 'started') {
        Diag.add('Установка через системный установщик не началась: $r');
        _applying = false;
        if (!interactive && !appVisible) return; // попробуем, когда Ласточку откроют
        final o = await OpenFilex.open(target.path, type: 'application/vnd.android.package-archive');
        if (o.type != ResultType.done) throw 'Разрешите Ласточке устанавливать приложения: Настройки → Приложения → Ласточка → Установка неизвестных приложений';
      }
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
