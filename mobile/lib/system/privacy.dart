// Защита экрана и следов на диске.
// • «Запретить снимки экрана»: Android — FLAG_SECURE (нет скриншотов, записи экрана и превью в недавних),
//   Windows — окно исключается из захвата экрана, macOS — окно не попадает в снимки и трансляции,
//   iPhone — при сворачивании содержимое закрывается заставкой.
// • Расшифрованные временные файлы (голосовые, открытые вложения) удаляются при запуске и выходе.
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _android = MethodChannel('lastochka/system');
const _mac = MethodChannel('lastochka/window');

final screenProtect = ValueNotifier<bool>(false);

Future<void> initPrivacy() async {
  final prefs = await SharedPreferences.getInstance();
  screenProtect.value = prefs.getBool('privacy.screen') ?? false;
  await _apply(screenProtect.value);
  await purgeDecryptedFiles();
}

Future<void> setScreenProtect(bool on) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setBool('privacy.screen', on);
  screenProtect.value = on;
  await _apply(on);
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
    if (hwnd != 0) aff(hwnd, on ? 0x11 : 0x0);
  } finally {
    calloc.free(cls);
    calloc.free(title);
  }
}

/// Папка для расшифрованных временных файлов — только внутри приложения.
Future<Directory> privateTemp() async {
  final base = await getApplicationSupportDirectory();
  return Directory(p.join(base.path, 'tmp-open')).create(recursive: true);
}

/// Удалить все расшифрованные временные файлы (голосовые, открытые вложения, записи).
Future<void> purgeDecryptedFiles() async {
  try {
    final d = Directory(p.join((await getApplicationSupportDirectory()).path, 'tmp-open'));
    if (await d.exists()) await d.delete(recursive: true);
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
