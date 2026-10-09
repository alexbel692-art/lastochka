import 'dart:io';

import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../main.dart';
import '../system/desktop.dart';
import '../system/notify.dart';
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
  SharedPreferences? _p;
  bool _battery = true, _autostart = true;

  @override
  void initState() {
    super.initState();
    client.fetchOwnProfile().then((p) {
      if (mounted) setState(() => _me = p);
    });
    SharedPreferences.getInstance().then((p) => mounted ? setState(() => _p = p) : null);
    isIgnoringBatteryOptimizations().then((v) => mounted ? setState(() => _battery = v) : null);
    autostartEnabled().then((v) => mounted ? setState(() => _autostart = v) : null);
  }

  bool _pref(String k, [bool def = true]) => _p?.getBool(k) ?? def;
  Future<void> _set(String k, bool v) async {
    await _p?.setBool(k, v);
    setState(() {});
  }

  Widget _switch(IconData icon, String title, String sub, bool value, ValueChanged<bool> onChanged) => SwitchListTile(
        secondary: Icon(icon, color: Theme.of(context).hintColor),
        title: Text(title),
        subtitle: Text(sub),
        value: value,
        onChanged: onChanged,
      );

  Widget _header(String t) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 18, 16, 4),
        child: Text(t, style: TextStyle(color: Theme.of(context).colorScheme.primary, fontWeight: FontWeight.w600)),
      );

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
        _header('Уведомления'),
        _switch(Icons.notifications_outlined, 'Уведомления', 'О новых сообщениях и звонках', _pref('notify.enabled'), (v) => _set('notify.enabled', v)),
        _switch(Icons.short_text, 'Текст сообщения', 'Показывать текст в уведомлении (иначе — «Новое сообщение»)', _pref('notify.text'), (v) => _set('notify.text', v)),
        if (Platform.isAndroid) ...[
          _switch(Icons.sync, 'Работать в фоне', 'Сообщения и звонки приходят, даже когда Ласточка закрыта', _pref('bg.enabled'), (v) async {
            await _set('bg.enabled', v);
            v ? await startBackgroundService() : await stopBackgroundService();
          }),
          if (!_battery)
            _row(Icons.battery_alert_outlined, 'Разрешить работу без ограничений', sub: 'Иначе телефон может «усыплять» Ласточку и звонки будут опаздывать', color: Colors.orange, onTap: () async {
              await requestIgnoreBatteryOptimizations();
              await Future.delayed(const Duration(seconds: 2));
              final v = await isIgnoringBatteryOptimizations();
              if (mounted) setState(() => _battery = v);
            }),
          _row(Icons.notifications_active_outlined, 'Разрешения для уведомлений и звонков', sub: 'Если уведомления не приходят', onTap: requestNotificationPermission),
        ],
        if (Platform.isWindows)
          _switch(Icons.power_settings_new, 'Запускать вместе с Windows', 'Ласточка тихо запускается в трее и принимает звонки', _autostart, (v) async {
            await setAutostart(v);
            setState(() => _autostart = v);
          }),
        if (isDesktopOS)
          _row(Icons.info_outline, 'Закрытие окна', sub: 'Крестик прячет Ласточку в ${Platform.isMacOS ? 'строку меню' : 'трей'} — сообщения и звонки продолжают приходить. Выйти полностью можно через меню значка.'),
        if (Platform.isIOS)
          _row(Icons.info_outline, 'Уведомления на iPhone', sub: 'Приходят, пока Ласточка открыта или недавно свёрнута. Чтобы они приходили всегда, нужен сервер push-уведомлений Apple.'),
        _header('О программе'),
        _row(Icons.info_outline, 'Ласточка', sub: 'Защищённый мессенджер на Matrix'),
        if (isDesktopOS) _row(Icons.close, 'Выйти из Ласточки', sub: 'Закрыть программу полностью', onTap: quitApp),
        const Divider(),
        _row(Icons.logout, 'Выйти', color: Colors.redAccent, onTap: () => logout(context)),
      ]))),
    );
  }
}
