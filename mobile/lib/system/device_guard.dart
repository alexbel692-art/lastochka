// Системные защиты iPhone (часть — и Mac) — вызовы модуля packages/device_guard.
//
// • Резервные копии. По умолчанию iPhone кладёт папку приложения в копию iCloud или компьютера,
//   а ключ базы из связки ключей — в зашифрованную копию. Из такой копии переписку и «личность»
//   устройства (ключи шифрования) можно было бы развернуть на другом iPhone. Ласточка отмечает свои
//   данные «не копировать», а ключ базы хранит «только на этом устройстве» — как Android с allowBackup=false.
// • Буфер обмена. Скопированное на iPhone по умолчанию уходит на Mac и iPad («Универсальный буфер»)
//   и лежит там бессрочно. Секреты копируются только на этот телефон и удаляются сами.
// • Запись экрана. Снимок экрана iPhone запретить нельзя, но запись экрана, AirPlay и повтор экрана
//   видны: при включённом «Запретить снимки экрана» переписка на это время закрывается заставкой.
// • Переключатель приложений. Заставка ставится системными средствами в момент сворачивания —
//   снимок для переключателя iPhone делает сразу, и картинка Flutter могла не успеть смениться.
// • Face ID / Touch ID. Если на устройстве добавили новое лицо или палец (например, кто-то подсмотрел
//   код телефона и добавил своё лицо), Ласточка перестаёт открываться по биометрии до ввода её кода.
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:matrix/matrix.dart';

const _ch = MethodChannel('lastochka/device_guard');

bool get _darwin => Platform.isIOS || Platform.isMacOS;

/// Идёт запись экрана, трансляция AirPlay или повтор экрана (только iPhone).
final screenCaptured = ValueNotifier<bool>(false);

/// Нужна ли заставка в переключателе приложений (задаётся при запуске: снимки экрана запрещены или есть код-пароль).
bool Function()? switcherCoverWanted;

/// Сообщить системной части iPhone, закрывать ли окно заставкой при сворачивании.
Future<void> syncSwitcherCover() async {
  if (!Platform.isIOS) return;
  try {
    await _ch.invokeMethod('switcherCover', switcherCoverWanted?.call() ?? false);
  } catch (_) {}
}

Future<void> initDeviceGuard() async {
  if (!Platform.isIOS) return;
  await syncSwitcherCover();
  _ch.setMethodCallHandler((c) async {
    if (c.method == 'captured') screenCaptured.value = c.arguments == true;
    return null;
  });
  try {
    screenCaptured.value = await _ch.invokeMethod<bool>('isCaptured') ?? false;
  } catch (_) {}
}

/// Отметить файлы и папки «не включать в резервные копии» (iPhone). Возвращает, сколько отмечено.
Future<int> excludeFromBackup(List<String> paths) async {
  if (!Platform.isIOS) return 0;
  try {
    final n = await _ch.invokeMethod<int>('excludeFromBackup', paths) ?? 0;
    if (n == 0) Logs().w('[Ласточка] не удалось исключить данные из резервных копий');
    return n;
  } catch (e) {
    Logs().w('[Ласточка] исключение из резервных копий', e);
    return 0;
  }
}

/// Скопировать секрет только на этот iPhone (без «Универсального буфера»), с удалением через [after].
/// false — не получилось (не iPhone или ошибка): вызывающий копирует обычным способом.
Future<bool> copySecretIos(String text, Duration after) async {
  if (!Platform.isIOS) return false;
  try {
    return await _ch.invokeMethod<bool>('copySecret', {'text': text, 'seconds': after.inSeconds.toDouble()}) ?? false;
  } catch (_) {
    return false;
  }
}

/// Текущий набор лиц/пальцев Face ID / Touch ID (iPhone и Mac). null — нет биометрии или не поддерживается.
Future<String?> biometricState() async {
  if (!_darwin) return null;
  try {
    return await _ch.invokeMethod<String>('bioState');
  } catch (_) {
    return null;
  }
}
