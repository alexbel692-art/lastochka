// Заставка при запуске: ласточка «влетает» на синем фоне, пока открывается защищённое хранилище.
// Затем плавно сменяется приложением.
import 'dart:math';

import 'package:flutter/material.dart';

const splashBlue = Color(0xFF2F7FE8);

/// Корень приложения: пока [app] пусто — заставка, потом плавный переход.
final appReady = ValueNotifier<Widget?>(null);

class Root extends StatelessWidget {
  const Root({super.key});
  @override
  Widget build(BuildContext context) => Directionality(
        textDirection: TextDirection.ltr,
        child: ValueListenableBuilder<Widget?>(
          valueListenable: appReady,
          builder: (_, app, __) => AnimatedSwitcher(
            duration: const Duration(milliseconds: 450),
            switchInCurve: Curves.easeOut,
            child: app ?? const SplashScreen(key: ValueKey('splash')),
          ),
        ),
      );
}

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});
  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> with TickerProviderStateMixin {
  // влёт и появление — один раз; лёгкое «парение» и точки загрузки — по кругу
  late final AnimationController _in = AnimationController(vsync: this, duration: const Duration(milliseconds: 900))..forward();
  late final AnimationController _loop = AnimationController(vsync: this, duration: const Duration(milliseconds: 1600))..repeat();

  @override
  void dispose() {
    _in.dispose();
    _loop.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final fly = CurvedAnimation(parent: _in, curve: Curves.easeOutBack);
    final fade = CurvedAnimation(parent: _in, curve: const Interval(0.0, 0.6, curve: Curves.easeOut));
    final title = CurvedAnimation(parent: _in, curve: const Interval(0.45, 1.0, curve: Curves.easeOut));
    return ColoredBox(
      color: splashBlue,
      child: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: RadialGradient(center: Alignment(0, -0.2), radius: 1.1, colors: [Color(0xFF4A95F0), splashBlue, Color(0xFF1E5FC4)], stops: [0, 0.55, 1]),
        ),
        child: Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            AnimatedBuilder(
              animation: Listenable.merge([_in, _loop]),
              builder: (_, child) {
                final hover = sin(_loop.value * 2 * pi) * 4; // парит вверх-вниз
                return Opacity(
                  opacity: fade.value.clamp(0.0, 1.0),
                  child: Transform.translate(
                    offset: Offset(-60 * (1 - fly.value), 30 * (1 - fly.value) + hover),
                    child: Transform.rotate(angle: -0.25 * (1 - fly.value), child: Transform.scale(scale: 0.6 + 0.4 * fly.value, child: child)),
                  ),
                );
              },
              child: Container(
                width: 112,
                height: 112,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(30),
                  boxShadow: const [BoxShadow(color: Color(0x40000000), blurRadius: 24, offset: Offset(0, 10))],
                ),
                child: ClipRRect(borderRadius: BorderRadius.circular(30), child: Image.asset('assets/icon.png', fit: BoxFit.cover)),
              ),
            ),
            const SizedBox(height: 22),
            FadeTransition(
              opacity: title,
              child: SlideTransition(
                position: Tween(begin: const Offset(0, 0.4), end: Offset.zero).animate(title),
                child: const Text('Ласточка', style: TextStyle(color: Colors.white, fontSize: 30, fontWeight: FontWeight.w700, letterSpacing: 0.5, decoration: TextDecoration.none)),
              ),
            ),
            const SizedBox(height: 26),
            AnimatedBuilder(
              animation: _loop,
              builder: (_, __) => Row(mainAxisSize: MainAxisSize.min, children: [
                for (var i = 0; i < 3; i++)
                  Container(
                    width: 8,
                    height: 8,
                    margin: const EdgeInsets.symmetric(horizontal: 4),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.white.withValues(alpha: 0.35 + 0.65 * (0.5 + 0.5 * sin((_loop.value - i * 0.15) * 2 * pi)).clamp(0.0, 1.0)),
                    ),
                  ),
              ]),
            ),
          ]),
        ),
      ),
    );
  }
}
