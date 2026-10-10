// Оформление: тема, размер текста, обои чатов.
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class Wallpaper {
  final String name;
  final List<Color> light, dark;
  const Wallpaper(this.name, this.light, this.dark);
}

const wallpapers = [
  Wallpaper('Сад', [Color(0xFFDCE6B8), Color(0xFFB7CF96), Color(0xFF9DC28A)], [Color(0xFF0F1B14), Color(0xFF16201A), Color(0xFF0D1712)]),
  Wallpaper('Небо', [Color(0xFFCFE3F7), Color(0xFFA9CBEF), Color(0xFF8DB8E8)], [Color(0xFF0E1621), Color(0xFF152233), Color(0xFF0B131C)]),
  Wallpaper('Закат', [Color(0xFFF9E1C8), Color(0xFFF2C0A8), Color(0xFFE7A3A6)], [Color(0xFF1E1416), Color(0xFF2A1A1E), Color(0xFF181012)]),
  Wallpaper('Лаванда', [Color(0xFFE6DDF7), Color(0xFFD2C4F0), Color(0xFFBFAEE8)], [Color(0xFF17131F), Color(0xFF211A2D), Color(0xFF120F18)]),
  Wallpaper('Мята', [Color(0xFFD5F1E8), Color(0xFFB2E3D3), Color(0xFF94D6C2)], [Color(0xFF0F1A18), Color(0xFF142422), Color(0xFF0B1413)]),
  Wallpaper('Без обоев', [Color(0xFFF1F1F3), Color(0xFFF1F1F3)], [Color(0xFF181818), Color(0xFF181818)]),
];

class Appearance {
  Appearance._();
  static final instance = Appearance._();

  final themeMode = ValueNotifier<ThemeMode>(ThemeMode.system);
  final textScale = ValueNotifier<double>(1.0);
  final wallpaper = ValueNotifier<int>(0);
  SharedPreferences? _p;

  Listenable get all => Listenable.merge([themeMode, textScale, wallpaper]);

  Future<void> init() async {
    _p = await SharedPreferences.getInstance();
    themeMode.value = ThemeMode.values.elementAtOrNull(_p!.getInt('look.theme') ?? 0) ?? ThemeMode.system;
    textScale.value = (_p!.getDouble('look.scale') ?? 1.0).clamp(0.8, 1.4);
    wallpaper.value = (_p!.getInt('look.wall') ?? 0).clamp(0, wallpapers.length - 1);
  }

  Future<void> setTheme(ThemeMode m) async {
    themeMode.value = m;
    await _p?.setInt('look.theme', m.index);
  }

  Future<void> setScale(double v) async {
    textScale.value = v;
    await _p?.setDouble('look.scale', v);
  }

  Future<void> setWallpaper(int i) async {
    wallpaper.value = i;
    await _p?.setInt('look.wall', i);
  }

  Gradient gradient(BuildContext c) {
    final w = wallpapers[wallpaper.value];
    final colors = Theme.of(c).brightness == Brightness.dark ? w.dark : w.light;
    return LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: colors);
  }
}
