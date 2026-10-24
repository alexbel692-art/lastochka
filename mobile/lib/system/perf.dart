// Облегчённый режим для удалённого рабочего стола (RDP): там нет видеокарты и каждый кадр
// рисуется процессором сервера на всех пользователей — анимации и «волны» от нажатий
// заметно тормозят. В RDP-сеансе они выключаются автоматически.
import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

final bool remoteSession = _detect();

/// Windows Server (например, RDP-сервер 2019). Видеомодуль Windows (Media Foundation) там часто неполный:
/// без нужных кодеков или видеообработки он может уронить всю программу при разборе видео.
final bool windowsServer = Platform.isWindows && Platform.operatingSystemVersion.contains('Server');

/// Встроенные видео-функции Windows (кадр-превью, проигрыватель внутри Ласточки) включены только на
/// обычном компьютере. На сервере и в RDP-сеансе видео открывается в проигрывателе системы — не роняя Ласточку.
final bool windowsMediaSafe = !(Platform.isWindows && (windowsServer || remoteSession));

bool _detect() {
  if (!Platform.isWindows) return false;
  try {
    final user32 = DynamicLibrary.open('user32.dll');
    final metrics = user32.lookupFunction<Int32 Function(Int32), int Function(int)>('GetSystemMetrics');
    const smRemoteSession = 0x1000;
    return metrics(smRemoteSession) != 0;
  } catch (_) {
    return false;
  }
}

/// Тема для RDP: без волн от нажатий и без анимации переходов между экранами.
ThemeData liteTheme(ThemeData t) => !remoteSession
    ? t
    : t.copyWith(
        splashFactory: NoSplash.splashFactory,
        pageTransitionsTheme: const PageTransitionsTheme(builders: {
          TargetPlatform.windows: _NoTransition(),
          TargetPlatform.linux: _NoTransition(),
          TargetPlatform.macOS: _NoTransition(),
        }),
      );

class _NoTransition extends PageTransitionsBuilder {
  const _NoTransition();
  @override
  Widget buildTransitions<T>(PageRoute<T> route, BuildContext context, Animation<double> animation, Animation<double> secondaryAnimation, Widget child) => child;
}

/// Экран сеанса виден человеку: Windows не заблокирован и сеанс RDP подключён.
/// Если человек просто отключился от RDP или заблокировал экран, Ласточка продолжает работать
/// (сообщения и уведомления приходят), но анимации на это время останавливаются: кадры, которые
/// никто не видит, иначе рисовал бы процессор сервера.
final ValueNotifier<bool> screenShown = ValueNotifier(true);
Timer? _screenWatch;

void startScreenWatch() {
  if (!Platform.isWindows || _screenWatch != null) return;
  late final _InputDesktop api;
  try {
    api = _InputDesktop();
  } catch (_) {
    return;
  }
  _screenWatch = Timer.periodic(const Duration(seconds: 3), (_) {
    final shown = api.userDesktopShown();
    if (shown == screenShown.value) return;
    screenShown.value = shown;
    // вернулись к экрану — сразу свежий кадр
    if (shown) SchedulerBinding.instance.scheduleForcedFrame();
  });
}

class _InputDesktop {
  final int Function(int, int, int) _open;
  final int Function(int) _close;
  final int Function(int, int, Pointer<Uint16>, int, Pointer<Uint32>) _info;

  factory _InputDesktop() {
    final u = DynamicLibrary.open('user32.dll');
    return _InputDesktop._(
      u.lookupFunction<IntPtr Function(Uint32, Int32, Uint32), int Function(int, int, int)>('OpenInputDesktop'),
      u.lookupFunction<Int32 Function(IntPtr), int Function(int)>('CloseDesktop'),
      u.lookupFunction<Int32 Function(IntPtr, Int32, Pointer<Uint16>, Uint32, Pointer<Uint32>),
          int Function(int, int, Pointer<Uint16>, int, Pointer<Uint32>)>('GetUserObjectInformationW'),
    );
  }
  _InputDesktop._(this._open, this._close, this._info);

  /// Сейчас на экране обычный рабочий стол пользователя (не экран блокировки и не отключённый сеанс).
  bool userDesktopShown() {
    const desktopReadObjects = 0x0001, uoiName = 2;
    final d = _open(0, 0, desktopReadObjects);
    if (d == 0) return false; // сеанс отключён или экран заблокирован (рабочий стол Winlogon)
    final name = calloc<Uint16>(64);
    final needed = calloc<Uint32>();
    try {
      if (_info(d, uoiName, name, 128, needed) == 0) return true;
      return name.cast<Utf16>().toDartString().toLowerCase() == 'default';
    } catch (_) {
      return true;
    } finally {
      calloc.free(name);
      calloc.free(needed);
      _close(d);
    }
  }
}
