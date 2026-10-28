// Защита экрана и следов на диске.
// • «Запретить снимки экрана»: Android — FLAG_SECURE (нет скриншотов, записи экрана и превью в недавних),
//   Windows — окно исключается из захвата экрана, macOS — окно не попадает в снимки и трансляции,
//   iPhone — при сворачивании содержимое закрывается заставкой.
// • Расшифрованные временные файлы (голосовые, открытые вложения) удаляются при запуске и выходе.
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:matrix/matrix.dart' show Client, PresenceType;

import 'device_guard.dart';

const _android = MethodChannel('lastochka/system');
const _mac = MethodChannel('lastochka/window');

final screenProtect = ValueNotifier<bool>(false);

/// Отправлять собеседникам отметки о прочтении (две галочки) и «печатает…».
/// Без отметок о прочтении Ласточка шлёт только личную отметку (MSC2285): она видна лишь вашим
/// устройствам — счётчик непрочитанного совпадает везде, а собеседник прочтения не видит.
bool sendReadReceipts = true;
bool sendTyping = true;

Future<void> setSendReadReceipts(bool on) async {
  sendReadReceipts = on;
  await (await SharedPreferences.getInstance()).setBool('privacy.readReceipts', on);
}

Future<void> setSendTyping(bool on) async {
  sendTyping = on;
  await (await SharedPreferences.getInstance()).setBool('privacy.typing', on);
}

/// Показывать собеседникам, когда вы в сети («в сети», «был(а) 5 минут назад»). Как в Telegram:
/// кто скрыл своё время, тот не видит и чужое.
bool showOnline = true;

Future<void> setShowOnline(Client c, bool on) async {
  showOnline = on;
  await (await SharedPreferences.getInstance()).setBool('privacy.online', on);
  c.syncPresence = on ? null : PresenceType.offline;
  final me = c.userID;
  if (me != null) await c.setPresence(me, on ? PresenceType.online : PresenceType.offline).catchError((Object _) {});
}

Future<void> initPrivacy() async {
  final prefs = await SharedPreferences.getInstance();
  screenProtect.value = prefs.getBool('privacy.screen') ?? false;
  sendReadReceipts = prefs.getBool('privacy.readReceipts') ?? true;
  sendTyping = prefs.getBool('privacy.typing') ?? true;
  showOnline = prefs.getBool('privacy.online') ?? true;
  await _apply(screenProtect.value);
  await purgeDecryptedFiles();
}

Future<void> setScreenProtect(bool on) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setBool('privacy.screen', on);
  screenProtect.value = on;
  await _apply(on);
  await syncSwitcherCover();
}

Future<void> _apply(bool on) async {
  try {
    if (Platform.isAndroid) {
      await _android.invokeMethod('secure', on);
    } else if (Platform.isMacOS) {
      await _mac.invokeMethod('protect', on);
    } else if (Platform.isWindows) {
      _windowsAffinity(on);
    }
  } catch (_) {}
}

// Windows: SetWindowDisplayAffinity(WDA_EXCLUDEFROMCAPTURE) — окно не видно на снимках и в записи экрана
typedef _FindNative = IntPtr Function(Pointer<Utf16>, Pointer<Utf16>);
typedef _FindDart = int Function(Pointer<Utf16>, Pointer<Utf16>);
typedef _AffNative = Int32 Function(IntPtr, Uint32);
typedef _AffDart = int Function(int, int);

void _windowsAffinity(bool on) {
  final user32 = DynamicLibrary.open('user32.dll');
  final find = user32.lookupFunction<_FindNative, _FindDart>('FindWindowW');
  final aff = user32.lookupFunction<_AffNative, _AffDart>('SetWindowDisplayAffinity');
  final cls = 'FLUTTER_RUNNER_WIN32_WINDOW'.toNativeUtf16();
  final title = 'Ласточка'.toNativeUtf16();
  try {
    final hwnd = find(cls, title);
    // 0x11 — исключить из захвата (Windows 10 2004+); на старых — 0x1 (чёрный прямоугольник вместо окна)
    if (hwnd != 0 && aff(hwnd, on ? 0x11 : 0x0) == 0 && on) aff(hwnd, 0x1);
  } finally {
    calloc.free(cls);
    calloc.free(title);
  }
}

/// Папка для расшифрованных временных файлов — только внутри приложения
/// (на телефоне — в кэше приложения, откуда их может открыть просмотрщик).
/// Windows — личная временная папка пользователя (не «Roaming»: она уезжает на сервер профилей при выходе из RDP).
Future<Directory> _privateBase() async =>
    Platform.isAndroid || Platform.isIOS || Platform.isWindows ? await getTemporaryDirectory() : await getApplicationSupportDirectory();

/// Имя временного файла по id сообщения — без совпадений между разными сообщениями.
String tempKey(String id) => sha256.convert(utf8.encode(id)).toString().substring(0, 32);

Future<Directory> privateTemp() async {
  final base = await _privateBase();
  return Directory(p.join(base.path, 'tmp-open')).create(recursive: true);
}

/// Удалить все расшифрованные временные файлы (голосовые, открытые вложения, записи).
Future<void> purgeDecryptedFiles() async {
  try {
    final d = Directory(p.join((await _privateBase()).path, 'tmp-open'));
    if (await d.exists()) await d.delete(recursive: true);
  } catch (_) {}
  // прежнее место на Windows (до 4.18) — в «Roaming»
  if (Platform.isWindows) {
    try {
      final old = Directory(p.join((await getApplicationSupportDirectory()).path, 'tmp-open'));
      if (await old.exists()) await old.delete(recursive: true);
    } catch (_) {}
  }
  // незавершённые отправки: SDK держит здесь открытую копию файла до успешной отправки
  try {
    final c = Directory(p.join((await getTemporaryDirectory()).path, 'lastochka_files'));
    if (await c.exists()) {
      await for (final f in c.list()) {
        if (p.basename(f.path).startsWith('cache_')) {
          try {
            await f.delete();
          } catch (_) {}
        }
      }
    }
  } catch (_) {}
  try {
    final t = await getTemporaryDirectory();
    await for (final f in t.list()) {
      final n = p.basename(f.path);
      if (n.startsWith('play_') || n.startsWith('voice_')) {
        try {
          await f.delete(recursive: true);
        } catch (_) {}
      }
    }
  } catch (_) {}
}
