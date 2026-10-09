// Работа в фоне:
// • Windows/macOS — закрытие окна прячет Ласточку в трей (строку меню), автозапуск с Windows;
// • Android — фоновая служба держит связь с сервером, исключение из экономии батареи.
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:matrix/matrix.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import 'notify.dart';

final bool isDesktopOS = Platform.isWindows || Platform.isMacOS || Platform.isLinux;
const _android = MethodChannel('lastochka/system');

// ---------------- Android ----------------

Future<void> startBackgroundService() async {
  if (!Platform.isAndroid) return;
  final prefs = await SharedPreferences.getInstance();
  await prefs.setBool('bg.loggedIn', true);
  if (prefs.getBool('bg.enabled') == false) return;
  try {
    await _android.invokeMethod('startService');
  } catch (e) {
    Logs().w('[Ласточка] фоновая служба не запущена', e);
  }
}

Future<void> stopBackgroundService() async {
  if (!Platform.isAndroid) return;
  await (await SharedPreferences.getInstance()).remove('bg.loggedIn');
  try {
    await _android.invokeMethod('stopService');
  } catch (_) {}
}

Future<bool> isIgnoringBatteryOptimizations() async {
  if (!Platform.isAndroid) return true;
  try {
    return await _android.invokeMethod<bool>('isIgnoringBattery') ?? true;
  } catch (_) {
    return true;
  }
}

Future<void> requestIgnoreBatteryOptimizations() async {
  if (!Platform.isAndroid) return;
  try {
    await _android.invokeMethod('requestIgnoreBattery');
  } catch (_) {}
}

// ---------------- Windows / macOS ----------------

class _WinListener with WindowListener {
  @override
  void onWindowClose() async {
    // как в Telegram: крестик прячет окно, Ласточка продолжает принимать сообщения и звонки
    await windowManager.hide();
    appVisible = false;
  }

  @override
  void onWindowFocus() => appVisible = true;

  @override
  void onWindowBlur() => appVisible = false;

  @override
  void onWindowMinimize() => appVisible = false;

  @override
  void onWindowRestore() => appVisible = true;
}

class _TrayListener with TrayListener {
  @override
  void onTrayIconMouseDown() => showMainWindow();

  @override
  void onTrayIconRightMouseDown() => trayManager.popUpContextMenu();

  @override
  void onTrayMenuItemClick(MenuItem item) {
    if (item.key == 'open') showMainWindow();
    if (item.key == 'quit') quitApp();
  }
}

Future<void> initDesktop() async {
  if (!isDesktopOS) return;
  try {
    await windowManager.ensureInitialized();
    await windowManager.setTitle('Ласточка');
    await windowManager.setMinimumSize(const Size(380, 520));
    await windowManager.setPreventClose(true);
    windowManager.addListener(_WinListener());
    await trayManager.setIcon(Platform.isWindows ? 'assets/tray.ico' : 'assets/tray.png');
    if (!Platform.isLinux) await trayManager.setToolTip('Ласточка');
    await trayManager.setContextMenu(Menu(items: [
      MenuItem(key: 'open', label: 'Открыть Ласточку'),
      MenuItem.separator(),
      MenuItem(key: 'quit', label: 'Выйти'),
    ]));
    trayManager.addListener(_TrayListener());
    await _syncAutostart();
  } catch (e) {
    Logs().w('[Ласточка] трей недоступен', e);
  }
}

Future<void> showMainWindow() async {
  if (!isDesktopOS) return;
  try {
    await windowManager.show();
    await windowManager.restore();
    await windowManager.focus();
    appVisible = true;
  } catch (_) {}
}

Future<void> hideMainWindow() async {
  if (!isDesktopOS) return;
  try {
    await windowManager.hide();
  } catch (_) {}
}

Future<void> quitApp() async {
  try {
    await trayManager.destroy();
    await windowManager.setPreventClose(false);
    await windowManager.destroy();
  } catch (_) {}
  exit(0);
}

// Автозапуск с Windows: ключ Run текущего пользователя (на RDP-сервере — у каждого свой).
const _runKey = r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run';

Future<bool> autostartEnabled() async {
  if (!Platform.isWindows) return false;
  return (await SharedPreferences.getInstance()).getBool('autostart') ?? true;
}

Future<void> setAutostart(bool on) async {
  if (!Platform.isWindows) return;
  await (await SharedPreferences.getInstance()).setBool('autostart', on);
  await _syncAutostart();
}

Future<void> _syncAutostart() async {
  if (!Platform.isWindows) return;
  final on = await autostartEnabled();
  try {
    if (on) {
      await Process.run('reg', ['add', _runKey, '/v', 'Lastochka', '/t', 'REG_SZ', '/d', '"${Platform.resolvedExecutable}" --hidden', '/f']);
    } else {
      await Process.run('reg', ['delete', _runKey, '/v', 'Lastochka', '/f']);
    }
  } catch (_) {}
}
