// Подтверждение входа: новое устройство нужно подтвердить ключом восстановления
// или с другого своего устройства (сравнение эмодзи), как в настольной версии.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:matrix/encryption/utils/key_verification.dart';

import '../main.dart';
import 'settings.dart';

bool needsVerification() =>
    client.encryption?.crossSigning.enabled == true && client.isUnknownSession;

class VerifyGate extends StatefulWidget {
  final Widget child;
  const VerifyGate({super.key, required this.child});
  @override
  State<VerifyGate> createState() => _VerifyGateState();
}

class _VerifyGateState extends State<VerifyGate> {
  StreamSubscription? _sub;
  final _key = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _sub = client.onSync.stream.listen((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _unlock() async {
    final input = _key.text.trim();
    if (input.isEmpty) return;
    setState(() { _busy = true; _error = null; });
    try {
      final enc = client.encryption!;
      await enc.ssss.open().unlock(keyOrPassphrase: input);
      await enc.keyManager.loadAllKeys();
      await client.updateUserDeviceKeys();
      if (!needsVerification()) setState(() {});
      if (needsVerification()) setState(() => _error = 'Ключ принят, подтверждение ещё синхронизируется…');
    } catch (e) {
      setState(() => _error = 'Неверный ключ восстановления');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _otherDevice() async {
    final keys = client.userDeviceKeys[client.userID!];
    if (keys == null) return;
    final req = await keys.startVerification();
    if (!mounted) return;
    await showVerificationDialog(context, req);
    await client.updateUserDeviceKeys();
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    if (!needsVerification()) return widget.child;
    final hint = Theme.of(context).hintColor;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 400),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Icon(Icons.shield_outlined, size: 72, color: Theme.of(context).colorScheme.primary),
                  const SizedBox(height: 16),
                  Text('Подтвердите вход', textAlign: TextAlign.center, style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 8),
                  Text('Чтобы читать зашифрованные сообщения, подтвердите это устройство ключом восстановления или с другого своего устройства.',
                      textAlign: TextAlign.center, style: TextStyle(color: hint)),
                  const SizedBox(height: 24),
                  TextField(
                    controller: _key,
                    autocorrect: false,
                    obscureText: true,
                    onSubmitted: (_) => _unlock(),
                    decoration: const InputDecoration(hintText: 'Ключ восстановления или фраза'),
                  ),
                  if (_error != null) Padding(padding: const EdgeInsets.only(top: 10), child: Text(_error!, style: const TextStyle(color: Colors.redAccent))),
                  const SizedBox(height: 14),
                  FilledButton(
                    onPressed: _busy ? null : _unlock,
                    style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(50)),
                    child: _busy ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white)) : const Text('Подтвердить ключом'),
                  ),
                  const SizedBox(height: 10),
                  OutlinedButton.icon(
                    onPressed: _busy ? null : _otherDevice,
                    style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(50)),
                    icon: const Icon(Icons.devices_outlined),
                    label: const Text('С другого устройства'),
                  ),
                  const SizedBox(height: 18),
                  TextButton(onPressed: () => logout(context), child: const Text('Выйти из аккаунта', style: TextStyle(color: Colors.redAccent))),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Входящий запрос: спросить, затем показать окно сравнения эмодзи.
Future<void> showIncomingVerification(BuildContext context, KeyVerification req) =>
    showVerificationDialog(context, req);

Future<void> showVerificationDialog(BuildContext context, KeyVerification req) => showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => _VerificationDialog(req),
    );

class _VerificationDialog extends StatefulWidget {
  final KeyVerification req;
  const _VerificationDialog(this.req);
  @override
  State<_VerificationDialog> createState() => _VerificationDialogState();
}

class _VerificationDialogState extends State<_VerificationDialog> {
  KeyVerification get req => widget.req;

  @override
  void initState() {
    super.initState();
    req.onUpdate = () {
      if (mounted) setState(() {});
    };
  }

  void _close() => Navigator.of(context).pop();

  @override
  Widget build(BuildContext context) {
    Widget body;
    List<Widget> actions;
    final who = req.userId == client.userID ? 'Другое ваше устройство' : req.userId;
    if (req.canceled) {
      body = Text('Подтверждение отменено${req.canceledReason != null ? ': ${req.canceledReason}' : ''}');
      actions = [TextButton(onPressed: _close, child: const Text('Закрыть'))];
    } else {
      switch (req.state) {
        case KeyVerificationState.askAccept:
          body = Text('$who запрашивает подтверждение. Принять?');
          actions = [
            TextButton(onPressed: () { req.rejectVerification(); _close(); }, child: const Text('Отклонить')),
            FilledButton(onPressed: () => req.acceptVerification(), child: const Text('Принять')),
          ];
        case KeyVerificationState.askChoice:
          body = const Text('Сравним эмодзи на обоих устройствах.');
          actions = [
            TextButton(onPressed: () { req.cancel(); _close(); }, child: const Text('Отмена')),
            FilledButton(onPressed: () => req.continueVerification('m.sas.v1'), child: const Text('Продолжить')),
          ];
        case KeyVerificationState.askSas:
          body = Column(mainAxisSize: MainAxisSize.min, children: [
            const Text('Убедитесь, что на другом устройстве те же эмодзи в том же порядке:'),
            const SizedBox(height: 16),
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 10,
              runSpacing: 12,
              children: [
                for (final e in req.sasEmojis)
                  SizedBox(width: 64, child: Column(children: [
                    Text(e.emoji, style: const TextStyle(fontSize: 34)),
                    Text(e.name, textAlign: TextAlign.center, style: const TextStyle(fontSize: 11)),
                  ])),
              ],
            ),
          ]);
          actions = [
            TextButton(onPressed: () { req.rejectSas(); _close(); }, child: const Text('Не совпадают')),
            FilledButton(onPressed: () => req.acceptSas(), child: const Text('Совпадают')),
          ];
        case KeyVerificationState.done:
          body = const Row(children: [Icon(Icons.verified_outlined, color: Colors.green), SizedBox(width: 10), Expanded(child: Text('Готово! Устройство подтверждено.'))]);
          actions = [FilledButton(onPressed: _close, child: const Text('Отлично'))];
        case KeyVerificationState.error:
          body = Text('Не удалось подтвердить${req.canceledReason != null ? ': ${req.canceledReason}' : ''}');
          actions = [TextButton(onPressed: _close, child: const Text('Закрыть'))];
        default:
          body = const Row(children: [
            SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5)),
            SizedBox(width: 14),
            Expanded(child: Text('Ожидание другого устройства…')),
          ]);
          actions = [TextButton(onPressed: () { req.cancel(); _close(); }, child: const Text('Отмена'))];
      }
    }
    return AlertDialog(title: const Text('Подтверждение'), content: body, actions: actions);
  }
}
