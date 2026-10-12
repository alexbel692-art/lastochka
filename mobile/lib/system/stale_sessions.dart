// Забытые входы (старый телефон, чужой компьютер) — частая лазейка: через них читают переписку.
// Раз в неделю проверяем сеансы, которыми не пользовались больше 30 дней, и предлагаем их завершить.
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../main.dart';
import '../pages/sessions.dart';
import 'diag.dart';

const staleAfter = Duration(days: 30);

Future<void> checkStaleSessions() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final last = prefs.getInt('sessions.staleAsked') ?? 0;
    if (DateTime.now().millisecondsSinceEpoch - last < const Duration(days: 7).inMilliseconds) return;
    final devices = await client.getDevices() ?? const [];
    final now = DateTime.now().millisecondsSinceEpoch;
    final stale = devices.where((d) => d.deviceId != client.deviceID && d.lastSeenTs != null && now - d.lastSeenTs! > staleAfter.inMilliseconds).toList();
    if (stale.isEmpty) return;
    await prefs.setInt('sessions.staleAsked', now);
    Diag.add('Неиспользуемых входов больше 30 дней: ${stale.length}');
    final ctx = navKey.currentContext;
    if (ctx == null || !ctx.mounted) return;
    final open = await showDialog<bool>(
      context: ctx,
      builder: (d) => AlertDialog(
        icon: const Icon(Icons.devices_other_rounded, size: 40),
        title: const Text('Есть забытые входы'),
        content: Text('В ваш аккаунт выполнен вход на ${stale.length} ${stale.length == 1 ? 'устройстве' : 'устройствах'}, которыми не пользовались больше месяца:\n\n'
            '${stale.take(5).map((d) => '• ${d.displayName ?? d.deviceId}').join('\n')}${stale.length > 5 ? '\n• …' : ''}\n\n'
            'Если это старые телефоны или чужие компьютеры — завершите эти сеансы, чтобы через них нельзя было читать переписку.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Позже')),
          FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('Открыть «Мои сеансы»')),
        ],
      ),
    );
    if (open == true && ctx.mounted) Navigator.of(ctx).push(MaterialPageRoute(builder: (_) => const SessionsPage()));
  } catch (e) {
    Diag.err('Проверка старых сеансов', e);
  }
}
