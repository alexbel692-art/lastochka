// Облегчённый режим для удалённого рабочего стола (RDP): там нет видеокарты и каждый кадр
// рисуется процессором сервера на всех пользователей — анимации и «волны» от нажатий
// заметно тормозят. В RDP-сеансе они выключаются автоматически.
import 'dart:ffi';
import 'dart:io';

import 'package:flutter/material.dart';

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
