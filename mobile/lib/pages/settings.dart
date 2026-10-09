import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart';

import '../main.dart';
import '../widgets/avatar.dart';
import 'login.dart';

Future<void> logout(BuildContext context) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      title: const Text('Выйти из аккаунта?'),
      content: const Text('Сообщения на этом устройстве будут удалены. Без ключа восстановления старые зашифрованные сообщения прочитать не получится.'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Отмена')),
        TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('Выйти', style: TextStyle(color: Colors.redAccent))),
      ],
    ),
  );
  if (ok != true) return;
  try {
    await client.logout();
  } catch (_) {
    await client.clear();
  }
  navKey.currentState?.pushAndRemoveUntil(MaterialPageRoute(builder: (_) => const LoginPage()), (_) => false);
}

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  Profile? _me;

  @override
  void initState() {
    super.initState();
    client.fetchOwnProfile().then((p) {
      if (mounted) setState(() => _me = p);
    });
  }

  Widget _row(IconData icon, String title, {String? sub, VoidCallback? onTap, Color? color}) => ListTile(
        leading: Icon(icon, color: color ?? Theme.of(context).hintColor),
        title: Text(title, style: TextStyle(color: color)),
        subtitle: sub == null ? null : Text(sub),
        onTap: onTap,
      );

  @override
  Widget build(BuildContext context) {
    final name = _me?.displayName ?? client.userID?.localpart ?? '';
    final verified = !client.isUnknownSession;
    return Scaffold(
      appBar: AppBar(title: const Text('Настройки')),
      body: Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 640), child: ListView(children: [
        const SizedBox(height: 16),
        Center(child: Avatar(mxc: _me?.avatarUrl, name: name, size: 96)),
        const SizedBox(height: 12),
        Text(name, textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600)),
        const SizedBox(height: 20),
        _row(verified ? Icons.verified_user_outlined : Icons.gpp_maybe_outlined, 'Это устройство',
            sub: verified ? 'Подтверждено, сообщения шифруются' : 'Не подтверждено'),
        _row(Icons.devices_outlined, 'Имя устройства', sub: client.deviceName ?? client.deviceID),
        _row(Icons.info_outline, 'О приложении', sub: 'Ласточка для телефона, ранняя версия'),
        const Divider(),
        _row(Icons.logout, 'Выйти', color: Colors.redAccent, onTap: () => logout(context)),
      ]))),
    );
  }
}
