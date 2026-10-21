import 'dart:io';

import 'package:flutter/material.dart';

import 'system/appearance.dart';

/// Шрифт интерфейса. Windows — системный Segoe UI: он подогнан под пиксели экрана (хинтинг), и на обычных
/// мониторах и особенно в RDP текст чёткий. Inter без этой подгонки на Windows выглядел «замыленным».
final String uiFont = Platform.isWindows ? 'Segoe UI' : 'Inter';

// Цвета как в настольной Ласточке (стиль Telegram).
const accentLight = Color(0xFF3390EC);
const accentDark = Color(0xFF8774E1);

ThemeData _base(Brightness b) {
  final dark = b == Brightness.dark;
  final accent = dark ? accentDark : accentLight;
  final bg = dark ? const Color(0xFF212121) : Colors.white;
  final scheme = ColorScheme.fromSeed(seedColor: accent, brightness: b).copyWith(
    primary: accent,
    surface: bg,
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    fontFamily: uiFont,
    // эмодзи и редкие символы — системными шрифтами
    fontFamilyFallback: const ['Segoe UI Emoji', 'Apple Color Emoji', 'Noto Color Emoji', 'Segoe UI', 'Roboto'],
    // короткие уведомления («Сохранено», «Скопировано») — маленькой плашкой по центру, а не полосой во всю ширину
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      width: 340,
      elevation: 3,
      backgroundColor: dark ? const Color(0xFF3A3A3C) : const Color(0xE6303035),
      contentTextStyle: TextStyle(color: Colors.white, fontSize: 14, fontFamily: uiFont),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    ),
    drawerTheme: const DrawerThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.horizontal(right: Radius.circular(22))),
    ),
    popupMenuTheme: PopupMenuThemeData(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
    dialogTheme: DialogThemeData(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22))),
    scaffoldBackgroundColor: bg,
    appBarTheme: AppBarTheme(
      backgroundColor: bg,
      foregroundColor: dark ? Colors.white : Colors.black,
      elevation: 0,
      scrolledUnderElevation: 0.5,
    ),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      backgroundColor: accent,
      foregroundColor: Colors.white,
      shape: const CircleBorder(),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: dark ? const Color(0xFF2C2C2C) : const Color(0xFFF4F4F5),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
    ),
  );
}

final lightTheme = _base(Brightness.light);
final darkTheme = _base(Brightness.dark);

/// Цвета пузырей сообщений.
class Bubbles {
  static Color out(BuildContext c) => Theme.of(c).brightness == Brightness.dark ? const Color(0xFF766AC8) : const Color(0xFFE3FEE0);
  static Color inc(BuildContext c) => Theme.of(c).brightness == Brightness.dark ? const Color(0xFF2B2B2B) : Colors.white;
  /// Фон чата — обои, выбранные в «Оформлении» (по умолчанию — мягкий градиент, как в Telegram).
  static Gradient wallGradient(BuildContext c) => Appearance.instance.gradient(c);
  static Color wall(BuildContext c) => (Appearance.instance.gradient(c) as LinearGradient).colors[1];
  static Color outText(BuildContext c) => Theme.of(c).brightness == Brightness.dark ? Colors.white : Colors.black;
}
