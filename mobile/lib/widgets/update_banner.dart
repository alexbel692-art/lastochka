import 'package:flutter/material.dart';

import '../system/updater.dart';

/// Полоска «Доступна новая версия» над списком чатов, как в Telegram Desktop.
class UpdateBanner extends StatelessWidget {
  const UpdateBanner({super.key});

  @override
  Widget build(BuildContext context) {
    final up = Updater.instance;
    return ListenableBuilder(
      listenable: Listenable.merge([up.available, up.progress, up.error]),
      builder: (context, _) {
        final u = up.available.value;
        if (u == null) return const SizedBox.shrink();
        final pr = up.progress.value;
        final accent = Theme.of(context).colorScheme.primary;
        return Material(
          color: accent.withValues(alpha: 0.1),
          child: InkWell(
            onTap: pr == null ? up.install : null,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
                Row(children: [
                  Icon(Icons.system_update_alt, color: accent),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      pr != null ? 'Загрузка обновления ${(pr * 100).round()}%…' : 'Доступна Ласточка ${u.version} — нажмите, чтобы обновить',
                      style: TextStyle(color: accent, fontWeight: FontWeight.w600),
                    ),
                  ),
                ]),
                if (pr != null) Padding(padding: const EdgeInsets.only(top: 8), child: LinearProgressIndicator(value: pr)),
                if (up.error.value != null) Padding(padding: const EdgeInsets.only(top: 6), child: Text(up.error.value!, style: const TextStyle(color: Colors.redAccent, fontSize: 13))),
              ]),
            ),
          ),
        );
      },
    );
  }
}
