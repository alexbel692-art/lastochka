// Копирование текста из переписки: через минуту буфер обмена очищается сам,
// на Android 13+ текст ещё и помечается секретным (не виден в подсказках клавиатуры и превью).
import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

const _system = MethodChannel('lastochka/system');
Timer? _clearTimer;

Future<void> copySensitive(String text, {Duration clearAfter = const Duration(seconds: 60)}) async {
  _clearTimer?.cancel();
  if (Platform.isAndroid) {
    try {
      final stamp = await _system.invokeMethod<int>('copySensitive', text);
      _clearTimer = Timer(clearAfter, () => _system.invokeMethod('clearClip', stamp).catchError((_) => null));
      return;
    } catch (_) {}
  }
  await Clipboard.setData(ClipboardData(text: text));
  // iPhone показывает «Ласточка вставила из…» при чтении буфера — там только копируем
  if (Platform.isIOS) return;
  _clearTimer = Timer(clearAfter, () async {
    try {
      final cur = await Clipboard.getData(Clipboard.kTextPlain);
      if (cur?.text == text) await Clipboard.setData(const ClipboardData(text: ''));
    } catch (_) {}
  });
}
