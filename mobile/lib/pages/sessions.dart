import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:matrix/matrix.dart';

import '../main.dart';
import '../system/trust.dart';

/// Мои сеансы: где выполнен вход в аккаунт, какие устройства подтверждены; завершение чужих входов.
class SessionsPage extends StatefulWidget {
  const SessionsPage({super.key});
  @override
  State<SessionsPage> createState() => _SessionsPageState();
}

class _SessionsPageState extends State<SessionsPage> {
  List<Device>? _devices;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final d = await client.getDevices() ?? [];
      d.sort((a, b) {
        if (a.deviceId == client.deviceID) return -1;
        if (b.deviceId == client.deviceID) return 1;
        return (b.lastSeenTs ?? 0).compareTo(a.lastSeenTs ?? 0);
      });
      if (mounted) setState(() => _devices = d);
    } catch (e) {
      if (mounted) setState(() => _error = 'Не удалось загрузить список сеансов');
    }
  }

  void _toast(String s) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s)));

  Future<void> _delete(List<String> ids, {required String what}) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text('Завершить $what?'),
        content: const Text('На этих устройствах произойдёт выход из аккаунта. Сервер может попросить подтвердить действие паролем.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Отмена')),
          TextButton(onPressed: () => Navigator.pop(d, true), child: const Text('Завершить', style: TextStyle(color: Colors.redAccent))),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _busy = true);
    try {
      await client.uiaRequestBackground((auth) => client.deleteDevices(ids, auth: auth));
      for (final id in ids) {
        await Trust.instance.confirmLogin(id);
      }
      _toast(ids.length == 1 ? 'Сеанс завершён' : 'Сеансы завершены');
      await _load();
    } catch (e) {
      _toast('Не удалось: ${e is MatrixException ? e.errorMessage : 'отменено или нет сети'}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final keys = client.userDeviceKeys[client.userID]?.deviceKeys ?? {};
    final hint = Theme.of(context).hintColor;
    final others = (_devices ?? []).where((d) => d.deviceId != client.deviceID).map((d) => d.deviceId).toList();
    return Scaffold(
      appBar: AppBar(title: const Text('Мои сеансы')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: _devices == null
              ? Center(child: _error != null ? Text(_error!) : const CircularProgressIndicator())
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(children: [
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text('Здесь все устройства, где выполнен вход в ваш аккаунт. Если видите незнакомое — завершите его и смените пароль.',
                          style: TextStyle(color: hint)),
                    ),
                    for (final d in _devices!)
                      _tile(d, keys[d.deviceId], hint),
                    if (others.isNotEmpty) ...[
                      const Divider(),
                      ListTile(
                        enabled: !_busy,
                        leading: const Icon(Icons.logout, color: Colors.redAccent),
                        title: const Text('Выйти на всех остальных устройствах', style: TextStyle(color: Colors.redAccent)),
                        onTap: () => _delete(others, what: 'все остальные сеансы'),
                      ),
                    ],
                  ]),
                ),
        ),
      ),
    );
  }

  Widget _tile(Device d, DeviceKeys? k, Color hint) {
    final current = d.deviceId == client.deviceID;
    final verified = k?.verified == true || k?.signed == true;
    final isNew = Trust.instance.newLogins.value.contains(d.deviceId);
    final seen = d.lastSeenTs == null ? null : DateTime.fromMillisecondsSinceEpoch(d.lastSeenTs!);
    return ListTile(
      leading: Icon(
        verified ? Icons.verified_user : Icons.gpp_maybe,
        color: verified ? Colors.green : Colors.orange,
      ),
      title: Text('${d.displayName ?? d.deviceId}${current ? ' — это устройство' : ''}'),
      subtitle: Text([
        verified ? 'Подтверждено' : 'Не подтверждено — ключи от переписки не получает',
        if (seen != null) 'был(о) в сети ${DateFormat('d MMM y, HH:mm', 'ru').format(seen)}',
        if (d.lastSeenIp != null) 'IP ${d.lastSeenIp}',
        if (isNew) 'Новый вход',
      ].join(' · ')),
      isThreeLine: true,
      trailing: current || _busy
          ? null
          : IconButton(tooltip: 'Завершить сеанс', icon: const Icon(Icons.logout, color: Colors.redAccent), onPressed: () => _delete([d.deviceId], what: 'этот сеанс')),
    );
  }
}
