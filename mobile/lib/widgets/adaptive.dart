// Открыть экран: на телефоне — как обычно, на весь экран; на компьютере и планшете — аккуратным окном
// по центру поверх приложения (как «Новый чат» и «Настройки» в Telegram Desktop).
// Внутри окна свой список экранов: переходы из настроек (оформление, сеансы…) открываются в нём же,
// а «назад» с первого экрана или клик мимо окна его закрывает.
import 'dart:math';

import 'package:flutter/material.dart';

bool isWideScreen(BuildContext context) => MediaQuery.sizeOf(context).width >= 720;

Future<T?> pushAdaptive<T>(BuildContext context, WidgetBuilder builder, {double maxWidth = 560}) {
  if (!isWideScreen(context)) return Navigator.of(context).push<T>(MaterialPageRoute(builder: builder));
  return showDialog<T>(
    context: context,
    useRootNavigator: true,
    builder: (_) => _DialogShell<T>(builder: builder, maxWidth: maxWidth),
  );
}

class _DialogShell<T> extends StatefulWidget {
  final WidgetBuilder builder;
  final double maxWidth;
  const _DialogShell({required this.builder, required this.maxWidth});
  @override
  State<_DialogShell<T>> createState() => _DialogShellState<T>();
}

class _DialogShellState<T> extends State<_DialogShell<T>> {
  late final MaterialPageRoute<T> _page = MaterialPageRoute<T>(builder: widget.builder, fullscreenDialog: true);
  bool _closed = false;

  @override
  void initState() {
    super.initState();
    // экран закрыли (крестик, «Готово», выбор человека) — закрываем и окно, передавая результат
    _page.popped.then((v) {
      if (_closed || !mounted) return;
      _closed = true;
      Navigator.of(context).pop<T>(v);
    });
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 28),
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      child: SizedBox(
        width: min(widget.maxWidth, size.width - 48),
        height: min(820.0, size.height - 56),
        child: Navigator(
          onGenerateInitialRoutes: (_, __) => [
            // подложка: на неё возвращаются, когда закрывают первый экран, — тогда закрывается окно
            PageRouteBuilder<void>(pageBuilder: (_, __, ___) => const SizedBox.shrink()),
            _page,
          ],
        ),
      ),
    );
  }
}
