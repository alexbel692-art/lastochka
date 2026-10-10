import 'dart:io';

import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../main.dart';
import '../system/desktop.dart';
import '../system/notify.dart';
import '../system/updater.dart';
import 'passcode.dart';
import 'appearance.dart';
import '../chat/drafts.dart';
import '../matrix_client.dart';
import 'package:image_picker/image_picker.dart';
import '../system/diag.dart';
import '../system/media_clean.dart';
import 'backup.dart';
import 'qr.dart';
import 'storage.dart';
import '../system/pinning.dart';
import '../system/clipboard.dart';
import 'sessions.dart';
import '../system/privacy.dart';
import '../system/trust.dart';
import '../widgets/avatar.dart';
import 'login.dart';

Future<void> logout(BuildContext context) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      title: const Text('Выйти из аккаунта?'),
      content: const Text('Сообщения на этом устройстве будут удалены. Без секретной фразы старую переписку потом прочитать не получится.'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Отмена')),
        TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('Выйти', style: TextStyle(color: Colors.redAccent))),
      ],
    ),
  );
  if (ok != true) return;
  await logoutNow();
}

/// Выйти без вопросов (после подтверждения).
Future<void> logoutNow() async {
  await purgeDecryptedFiles();
  await Trust.instance.resetOwnDevices();
  await Drafts.instance.clearAll().catchError((_) {});
  await Scheduler.instance.clearAll().catchError((_) {});
  try {
    await client.logout().timeout(const Duration(seconds: 10));
  } catch (_) {
    await client.clear();
  }
  navKey.currentState?.pushAndRemoveUntil(MaterialPageRoute(builder: (_) => const LoginPage()), (_) => false);
}

/// Экстренное удаление: всё, что Ласточка хранит на устройстве, стирается без вопросов.
/// Сначала — данные (экран блокировки остаётся, пока они не удалены), потом сеанс на сервере
/// завершается в фоне, и Ласточка закрывается: при следующем запуске — чистый экран входа.
Future<void> wipeDevice() async {
  final hs = client.homeserver, token = client.accessToken;
  try {
    await client.clear();
  } catch (_) {}
  try {
    await client.dispose(closeDatabase: true);
  } catch (_) {}
  await purgeDecryptedFiles();
  await wipeLocalStorage();
  try {
    await (await SharedPreferences.getInstance()).clear(); // и код-пароль, и черновики, и отложенные
  } catch (_) {}
  if (hs != null && token != null) {
    try {
      await CertPinning.instance.httpClient().post(hs.resolve('/_matrix/client/v3/logout'), headers: {'authorization': 'Bearer $token', 'content-type': 'application/json'}, body: '{}').timeout(const Duration(seconds: 4));
    } catch (_) {}
  }
  exit(0);
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

  void _toast(String s) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s)));

  Future<void> _changeName() async {
    final c = TextEditingController(text: _me?.displayName ?? '');
    final v = await showDialog<String>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('Ваше имя'),
        content: TextField(enableIMEPersonalizedLearning: false, controller: c, autofocus: true, maxLength: 64),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d), child: const Text('Отмена')),
          FilledButton(onPressed: () => Navigator.pop(d, c.text.trim()), child: const Text('Сохранить')),
        ],
      ),
    );
    if (v == null || v.isEmpty) return;
    try {
      await client.request(RequestType.PUT, '/client/v3/profile/${Uri.encodeComponent(client.userID!)}/displayname', data: {'displayname': v});
      // сервер уже обновил имя, а сохранённый профиль — ещё нет
      if (mounted) setState(() => _me = Profile(userId: client.userID!, displayName: v, avatarUrl: _me?.avatarUrl));
    } catch (_) {
      _toast('Не удалось сменить имя');
    }
  }

  Future<void> _changeAvatar() async {
    final x = await ImagePicker().pickImage(source: ImageSource.gallery, imageQuality: 95, maxWidth: 1024, requestFullMetadata: false);
    if (x == null) return;
    try {
      final clean = await cleanPhoto(await x.readAsBytes(), x.name);
      await client.setAvatar(MatrixFile(bytes: clean.bytes, name: clean.name));
      Uri? url;
      try {
        final r = await client.request(RequestType.GET, '/client/v3/profile/${Uri.encodeComponent(client.userID!)}');
        url = Uri.tryParse('${r['avatar_url'] ?? ''}');
      } catch (_) {}
      if (mounted) setState(() => _me = Profile(userId: client.userID!, displayName: _me?.displayName, avatarUrl: url ?? _me?.avatarUrl));
    } catch (_) {
      _toast('Не удалось сменить фото');
    }
  }

  Future<void> _diag() async {
    final text = await Diag.report();
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('Отчёт для диагностики'),
        content: SizedBox(width: 520, height: 420, child: SingleChildScrollView(child: SelectableText(text, style: const TextStyle(fontFamily: 'monospace', fontSize: 11.5)))),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d), child: const Text('Закрыть')),
          FilledButton(
            onPressed: () async {
              await copySensitive(text, clearAfter: const Duration(minutes: 5));
              if (d.mounted) Navigator.pop(d);
              _toast('Отчёт скопирован — вставьте его в сообщение разработчику');
            },
            child: const Text('Скопировать'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final name = _me?.displayName ?? client.userID?.localpart ?? '';
    final verified = !client.isUnknownSession;
    return Scaffold(
      appBar: AppBar(title: const Text('Настройки')),
      body: Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 640), child: ListView(children: [
        const SizedBox(height: 16),
        Center(
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: _changeAvatar,
            child: Stack(children: [
              Avatar(mxc: _me?.avatarUrl, name: name, size: 96),
              Positioned(
                right: 0,
                bottom: 0,
                child: CircleAvatar(radius: 15, backgroundColor: Theme.of(context).colorScheme.primary, child: const Icon(Icons.photo_camera, size: 16, color: Colors.white)),
              ),
            ]),
          ),
        ),
        const SizedBox(height: 12),
        InkWell(
          onTap: _changeName,
          child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            Flexible(child: Text(name, textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600))),
            const SizedBox(width: 6),
            Icon(Icons.edit_outlined, size: 18, color: Theme.of(context).hintColor),
          ]),
        ),
        Text(client.userID ?? '', textAlign: TextAlign.center, style: TextStyle(color: Theme.of(context).hintColor)),
        const SizedBox(height: 8),
        Center(
          child: TextButton.icon(
            icon: const Icon(Icons.qr_code_2),
            label: const Text('Мой QR-код'),
            onPressed: () => showQr(context, name, userLink(client.userID!), note: 'Отсканируйте в Ласточке, чтобы написать мне'),
          ),
        ),
        const SizedBox(height: 8),
        _row(verified ? Icons.verified_user_outlined : Icons.gpp_maybe_outlined, 'Это устройство',
            sub: verified ? 'Подтверждено, сообщения шифруются' : 'Не подтверждено'),
        _row(Icons.devices_outlined, 'Имя устройства', sub: client.deviceName ?? client.deviceID),
        _header('Конфиденциальность'),
        _row(Icons.lock_outline, 'Код-пароль', sub: _p?.getString('lock.hash')?.isNotEmpty == true ? 'Включён' : 'Выключен', onTap: () async {
          await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const PasscodePage()));
          setState(() {});
        }),
        FutureBuilder<BackupState>(
          future: backupState(),
          builder: (_, s) => _row(
            Icons.cloud_sync_outlined,
            'Резервная копия ключей',
            sub: backupText(s.data ?? BackupState.unknown),
            color: s.data == BackupState.missing || s.data == BackupState.notConnected ? Colors.orange.shade800 : null,
            onTap: () async {
              await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const BackupPage()));
              setState(() {});
            },
          ),
        ),
        _row(Icons.devices_other_outlined, 'Мои сеансы', sub: 'Где выполнен вход; завершить чужой вход', onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SessionsPage()))),
        _switch(Icons.screenshot_monitor_outlined, 'Запретить снимки экрана',
            Platform.isIOS ? 'Скрывать переписку в переключателе приложений' : 'Переписку нельзя сфотографировать или записать с экрана', screenProtect.value, (v) async {
          await setScreenProtect(v);
          setState(() {});
        }),
        _switch(Icons.how_to_reg_outlined, 'Принимать личные чаты автоматически', 'От коллег с вашего сервера — без нажатия «Вступить»', _pref('invites.autoAccept'), (v) => _set('invites.autoAccept', v)),
        _row(Icons.data_usage, 'Хранилище', sub: 'Сколько места занято, очистка кэша', onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const StoragePage()))),
        _header('Оформление'),
        _row(Icons.palette_outlined, 'Оформление', sub: 'Тема, размер текста, обои чатов', onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const AppearancePage()))),
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
        _row(Icons.bug_report_outlined, 'Отчёт для диагностики', sub: 'Версия, устройство и ошибки — без переписки, имён и адресов', onTap: _diag),
        _row(Icons.info_outline, 'Ласточка $appVersion', sub: 'Защищённый мессенджер'),
        if (Updater.instance.supported)
          _row(Icons.system_update_alt, 'Проверить обновления', sub: 'Обновления подписаны ключом разработчика и проверяются перед установкой', onTap: () async {
            final has = await Updater.instance.check();
            if (!context.mounted) return;
            if (has) {
              Navigator.of(context).popUntil((r) => r.isFirst);
            } else {
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('У вас последняя версия')));
            }
          }),
        if (isDesktopOS) _row(Icons.close, 'Выйти из Ласточки', sub: 'Закрыть программу полностью', onTap: quitApp),
        const Divider(),
        _row(Icons.logout, 'Выйти', color: Colors.redAccent, onTap: () => logout(context)),
      ]))),
    );
  }
}
