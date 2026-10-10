import 'package:flutter/material.dart';

import '../system/appearance.dart';
import '../theme.dart';
import '../widgets/bubble_shape.dart';

/// Тема, размер текста, обои — с живым предпросмотром, как в Telegram.
class AppearancePage extends StatelessWidget {
  const AppearancePage({super.key});

  @override
  Widget build(BuildContext context) {
    final a = Appearance.instance;
    final accent = Theme.of(context).colorScheme.primary;
    return Scaffold(
      appBar: AppBar(title: const Text('Оформление')),
      body: ListenableBuilder(
        listenable: a.all,
        builder: (context, _) => Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: ListView(children: [
              // предпросмотр
              Container(
                margin: const EdgeInsets.all(12),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(gradient: Bubbles.wallGradient(context), borderRadius: BorderRadius.circular(14)),
                child: Column(children: [
                  _preview(context, 'Привет! Как тебе новое оформление?', false),
                  const SizedBox(height: 6),
                  _preview(context, 'Отлично, текст читается легко 👍', true),
                ]),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                child: Text('Тема', style: TextStyle(color: accent, fontWeight: FontWeight.w600)),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: SegmentedButton<ThemeMode>(
                  segments: const [
                    ButtonSegment(value: ThemeMode.system, label: Text('Как в системе')),
                    ButtonSegment(value: ThemeMode.light, label: Text('Светлая')),
                    ButtonSegment(value: ThemeMode.dark, label: Text('Тёмная')),
                  ],
                  selected: {a.themeMode.value},
                  onSelectionChanged: (s) => a.setTheme(s.first),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 18, 16, 0),
                child: Text('Размер текста: ${(a.textScale.value * 100).round()}%', style: TextStyle(color: accent, fontWeight: FontWeight.w600)),
              ),
              Slider(
                value: a.textScale.value,
                min: 0.8,
                max: 1.4,
                divisions: 12,
                label: '${(a.textScale.value * 100).round()}%',
                onChanged: (v) => a.setScale(double.parse(v.toStringAsFixed(2))),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                child: Text('Обои чатов', style: TextStyle(color: accent, fontWeight: FontWeight.w600)),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Wrap(spacing: 10, runSpacing: 10, children: [
                  for (var i = 0; i < wallpapers.length; i++)
                    InkWell(
                      borderRadius: BorderRadius.circular(12),
                      onTap: () => a.setWallpaper(i),
                      child: Column(children: [
                        Container(
                          width: 84,
                          height: 120,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: a.wallpaper.value == i ? accent : Colors.transparent, width: 3),
                            gradient: LinearGradient(
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                              colors: Theme.of(context).brightness == Brightness.dark ? wallpapers[i].dark : wallpapers[i].light,
                            ),
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(wallpapers[i].name, style: const TextStyle(fontSize: 12.5)),
                      ]),
                    ),
                ]),
              ),
              const SizedBox(height: 24),
            ]),
          ),
        ),
      ),
    );
  }

  Widget _preview(BuildContext context, String text, bool mine) => Align(
        alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
        child: DecoratedBox(
          decoration: ShapeDecoration(color: mine ? Bubbles.out(context) : Bubbles.inc(context), shape: TgBubbleBorder(mine: mine, tail: true)),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 6, 10, 6).add(TgBubbleBorder(mine: mine, tail: true).dimensions),
            child: Text(text, style: TextStyle(fontSize: 16, color: mine ? Bubbles.outText(context) : null)),
          ),
        ),
      );
}
