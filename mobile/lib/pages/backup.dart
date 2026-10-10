// Резервная копия ключей переписки на сервере (зашифрована ключом восстановления — сервер её прочитать
// не может). Без неё при потере всех устройств старая переписка не расшифруется.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:matrix/encryption.dart';

import '../main.dart';
import '../system/diag.dart';

enum BackupState { unknown, ok, notConnected, missing }

Future<BackupState> backupState() async {
  final enc = client.encryption;
  if (enc == null) return BackupState.unknown;
  try {
    if (!enc.keyManager.enabled) return BackupState.missing;
    return await enc.keyManager.isCached() ? BackupState.ok : BackupState.notConnected;
  } catch (_) {
    return BackupState.unknown;
  }
}

String backupText(BackupState s) => switch (s) {
      BackupState.ok => 'Включена — новые ключи сохраняются',
      BackupState.notConnected => 'Есть, но это устройство к ней не подключено',
      BackupState.missing => 'Не включена — при потере устройств переписку не вернуть',
      BackupState.unknown => 'Проверяем…',
    };

class BackupPage extends StatefulWidget {
  const BackupPage({super.key});
  @override
  State<BackupPage> createState() => _BackupPageState();
}

class _BackupPageState extends State<BackupPage> {
  BackupState _s = BackupState.unknown;
  bool _busy = false;
  String? _msg;
  final _key = TextEditingController();

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final s = await backupState();
    if (mounted) setState(() => _s = s);
  }

  Future<void> _run(Future<void> Function() f, String ok) async {
    setState(() {
      _busy = true;
      _msg = null;
    });
    try {
      await f();
      _msg = ok;
    } catch (e) {
      Diag.add('Резервная копия: $e');
      _msg = e is StateError && e.message == 'key' ? 'Неверный ключ восстановления' : 'Не получилось. Проверьте ключ и подключение';
    }
    await _refresh();
    if (mounted) setState(() => _busy = false);
  }

  /// Подключить это устройство к существующей копии (ключом восстановления).
  Future<void> _connect() => _run(() async {
        final input = _key.text.trim();
        if (input.isEmpty) throw StateError('key');
        final enc = client.encryption!;
        try {
          await enc.ssss.open().unlock(keyOrPassphrase: input);
        } catch (_) {
          throw StateError('key');
        }
        await enc.keyManager.loadAllKeys();
        _key.clear();
      }, 'Готово: устройство подключено, старые ключи загружены');

  /// Создать копию ключей (ключ восстановления остаётся прежним).
  Future<void> _create() => _run(() async {
        final input = _key.text.trim();
        if (input.isEmpty) throw StateError('key');
        final done = Completer<void>();
        client.encryption!.bootstrap(onUpdate: (bs) async {
          try {
            switch (bs.state) {
              case BootstrapState.askWipeSsss:
                bs.wipeSsss(false);
              case BootstrapState.askUseExistingSsss:
                bs.useExistingSsss(true);
              case BootstrapState.askUnlockSsss:
                for (final k in bs.oldSsssKeys!.values) {
                  try {
                    await k.unlock(keyOrPassphrase: input);
                  } catch (_) {
                    if (!done.isCompleted) done.completeError(StateError('key'));
                    return;
                  }
                }
                bs.unlockedSsss();
              case BootstrapState.askBadSsss:
                bs.ignoreBadSecrets(true);
              case BootstrapState.askWipeCrossSigning:
                await bs.wipeCrossSigning(false);
              case BootstrapState.askSetupCrossSigning:
                await bs.askSetupCrossSigning(setupMasterKey: true, setupSelfSigningKey: true, setupUserSigningKey: true);
              case BootstrapState.askWipeOnlineKeyBackup:
                bs.wipeOnlineKeyBackup(false);
              case BootstrapState.askSetupOnlineKeyBackup:
                await bs.askSetupOnlineKeyBackup(true);
              case BootstrapState.askNewSsss:
                // ключа восстановления ещё нет — его создаёт первичная настройка защиты
                if (!done.isCompleted) done.completeError(StateError('nossss'));
              case BootstrapState.done:
                if (!done.isCompleted) done.complete();
              case BootstrapState.error:
                if (!done.isCompleted) done.completeError(StateError('bootstrap'));
              default:
                break;
            }
          } catch (e) {
            if (!done.isCompleted) done.completeError(e);
          }
        });
        await done.future.timeout(const Duration(minutes: 3));
        _key.clear();
      }, 'Готово: резервная копия ключей включена');

  Future<void> _restore() => _run(() => client.encryption!.keyManager.loadAllKeys(), 'Ключи из резервной копии загружены');

  @override
  Widget build(BuildContext context) {
    final hint = Theme.of(context).hintColor;
    final color = switch (_s) { BackupState.ok => Colors.green, BackupState.unknown => hint, _ => Colors.orange.shade800 };
    final needKey = _s == BackupState.notConnected || _s == BackupState.missing;
    return Scaffold(
      appBar: AppBar(title: const Text('Резервная копия ключей')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: ListView(padding: const EdgeInsets.all(20), children: [
            Icon(_s == BackupState.ok ? Icons.cloud_done_outlined : Icons.cloud_off_outlined, size: 64, color: color),
            const SizedBox(height: 12),
            Text(backupText(_s), textAlign: TextAlign.center, style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: color)),
            const SizedBox(height: 10),
            Text(
              'Ключи от переписки хранятся на сервере в зашифрованном виде — открыть их можно только вашим ключом восстановления. '
              'Если потеряете все устройства, по ключу восстановления вернётся вся старая переписка.',
              textAlign: TextAlign.center,
              style: TextStyle(color: hint),
            ),
            const SizedBox(height: 20),
            if (needKey) ...[
              TextField(
                enableIMEPersonalizedLearning: false,
                controller: _key,
                obscureText: true,
                autocorrect: false,
                decoration: const InputDecoration(hintText: 'Ключ восстановления'),
              ),
              const SizedBox(height: 12),
              FilledButton(
                style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                onPressed: _busy ? null : (_s == BackupState.missing ? _create : _connect),
                child: Text(_s == BackupState.missing ? 'Включить резервную копию' : 'Подключить это устройство'),
              ),
            ],
            if (_s == BackupState.ok)
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                onPressed: _busy ? null : _restore,
                icon: const Icon(Icons.restore),
                label: const Text('Загрузить старые ключи из копии'),
              ),
            if (_busy) const Padding(padding: EdgeInsets.all(16), child: Center(child: CircularProgressIndicator())),
            if (_msg != null) Padding(padding: const EdgeInsets.only(top: 14), child: Text(_msg!, textAlign: TextAlign.center)),
          ]),
        ),
      ),
    );
  }
}
