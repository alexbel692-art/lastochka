import 'package:flutter/material.dart';

import '../main.dart';
import '../pages/sessions.dart';
import '../system/trust.dart';

/// «Новый вход в ваш аккаунт — это вы?» над списком чатов.
class NewLoginBanner extends StatelessWidget {
  const NewLoginBanner({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<List<String>>(
      valueListenable: Trust.instance.newLogins,
      builder: (context, ids, _) {
        if (ids.isEmpty) return const SizedBox.shrink();
        final id = ids.first;
        final name = client.userDeviceKeys[client.userID]?.deviceKeys[id]?.deviceDisplayName ?? id;
        return Material(
          color: Colors.orange.withValues(alpha: 0.14),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 8, 6),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
              Row(children: [
                Icon(Icons.warning_amber_rounded, color: Colors.orange.shade800),
                const SizedBox(width: 10),
                Expanded(child: Text('Новый вход в ваш аккаунт: $name. Это вы?', style: const TextStyle(fontWeight: FontWeight.w600))),
              ]),
              Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                TextButton(onPressed: () => Trust.instance.confirmLogin(id), child: const Text('Да, это я')),
                TextButton(
                  onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SessionsPage())),
                  child: const Text('Нет — завершить', style: TextStyle(color: Colors.redAccent)),
                ),
              ]),
            ]),
          ),
        );
      },
    );
  }
}
