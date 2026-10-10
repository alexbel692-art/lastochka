// Подтверждение входа: новое устройство нужно подтвердить ключом восстановления
// или с другого своего устройства (сравнение эмодзи), как в настольной версии.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:matrix/encryption.dart';
import 'package:matrix/encryption/utils/key_verification.dart';

import '../main.dart';
import '../system/trust.dart';
import 'settings.dart';

/// Проверка новой секретной фразы. null — подходит.
String? phraseProblem(String p1, String p2) {
  if (p1.length < 12) return 'Фраза слишком короткая — нужно не меньше 12 символов';
  if (RegExp(r'^(.)\1+$').hasMatch(p1) || RegExp(r'^(0123|1234|qwer|йцук|abcd)', caseSensitive: false).hasMatch(p1)) return 'Слишком простая фраза — придумайте другую';
  if (p1 != p2) return 'Фразы не совпадают';
  return null;
}

bool needsVerification() =>
    client.encryption?.crossSigning.enabled == true && client.isUnknownSession;

/// У аккаунта ещё нет подписи устройств (новый аккаунт, ни разу не входили в Element/Ласточку).
/// Без неё любое новое устройство с паролем получало бы ключи — поэтому настраиваем сразу.
bool needsSecuritySetup() {
  final enc = client.encryption;
  return enc != null && client.prevBatch != null && !enc.crossSigning.enabled && enc.ssss.defaultKeyId == null;
}

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
      setState(() => _error = 'Неверная секретная фраза');
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

  // секретная фраза вместо ключа восстановления: ключ выводится из фразы и нигде не показывается
  final _p1 = TextEditingController(), _p2 = TextEditingController();
  bool _setupRunning = false, _show = false;
  String? _setupError;

  /// Первичная настройка защиты: ключ восстановления, подпись устройств, резервная копия ключей.
  Future<void> _runSetup() async {
    if (_setupRunning) return;
    final phrase = _p1.text.trim();
    final err = phraseProblem(phrase, _p2.text.trim());
    if (err != null) return setState(() => _setupError = err);
    setState(() {
      _setupRunning = true;
      _setupError = null;
    });
    final done = Completer<void>();
    client.encryption!.bootstrap(onUpdate: (bs) async {
      try {
        switch (bs.state) {
          case BootstrapState.askWipeSsss:
            bs.wipeSsss(false);
          case BootstrapState.askUseExistingSsss:
            bs.useExistingSsss(false);
          case BootstrapState.askBadSsss:
            bs.ignoreBadSecrets(true);
          case BootstrapState.askNewSsss:
            await bs.newSsss(phrase);
          case BootstrapState.askWipeCrossSigning:
            await bs.wipeCrossSigning(true);
          case BootstrapState.askSetupCrossSigning:
            await bs.askSetupCrossSigning(setupMasterKey: true, setupSelfSigningKey: true, setupUserSigningKey: true);
          case BootstrapState.askWipeOnlineKeyBackup:
            bs.wipeOnlineKeyBackup(false);
          case BootstrapState.askSetupOnlineKeyBackup:
            await bs.askSetupOnlineKeyBackup(true);
          case BootstrapState.done:
            if (!done.isCompleted) done.complete();
          case BootstrapState.error:
            if (!done.isCompleted) done.completeError(StateError('bootstrap'));
          case BootstrapState.askUnlockSsss:
            if (!done.isCompleted) done.completeError(StateError('ssss'));
          default:
            break;
        }
      } catch (e) {
        if (!done.isCompleted) done.completeError(e);
      }
    });
    try {
      await done.future.timeout(const Duration(minutes: 3));
      _p1.clear();
      _p2.clear();
      setState(() {});
    } catch (e) {
      setState(() => _setupError = 'Не удалось настроить защиту. Проверьте подключение и попробуйте ещё раз.');
    } finally {
      if (mounted) setState(() => _setupRunning = false);
    }
  }

  Widget _setupScreen(BuildContext context) {
    final hint = Theme.of(context).hintColor;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Icon(Icons.vpn_key_outlined, size: 64, color: Theme.of(context).colorScheme.primary),
                const SizedBox(height: 14),
                Text('Секретная фраза', textAlign: TextAlign.center, style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700)),
                const SizedBox(height: 10),
                Text(
                  'Придумайте фразу, которую знаете только вы. По ней вы будете подтверждать новые устройства и возвращать переписку. '
                  'Нигде её не записывайте в телефоне — просто запомните. Восстановить её нельзя: без фразы старую переписку на новом устройстве не прочитать.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: hint),
                ),
                const SizedBox(height: 18),
                TextField(
                  enableIMEPersonalizedLearning: false,
                  controller: _p1,
                  obscureText: !_show,
                  autocorrect: false,
                  decoration: InputDecoration(
                    hintText: 'Секретная фраза',
                    suffixIcon: IconButton(icon: Icon(_show ? Icons.visibility_off : Icons.visibility), onPressed: () => setState(() => _show = !_show)),
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  enableIMEPersonalizedLearning: false,
                  controller: _p2,
                  obscureText: !_show,
                  autocorrect: false,
                  onSubmitted: (_) => _runSetup(),
                  decoration: const InputDecoration(hintText: 'Повторите фразу'),
                ),
                const SizedBox(height: 8),
                Text('Не короче 12 символов, лучше 3–4 слова. Не используйте пароль от аккаунта.', style: TextStyle(color: hint, fontSize: 12.5)),
                if (_setupError != null) Padding(padding: const EdgeInsets.only(top: 10), child: Text(_setupError!, textAlign: TextAlign.center, style: const TextStyle(color: Colors.redAccent))),
                const SizedBox(height: 16),
                FilledButton(
                  style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(50)),
                  onPressed: _setupRunning ? null : _runSetup,
                  child: _setupRunning ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white)) : const Text('Сохранить фразу'),
                ),
                const SizedBox(height: 14),
                TextButton(onPressed: () => logout(context), child: const Text('Выйти из аккаунта', style: TextStyle(color: Colors.redAccent))),
              ]),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (needsSecuritySetup()) return _setupScreen(context);
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
                  Text('Чтобы читать переписку, подтвердите это устройство секретной фразой или с другого своего устройства.',
                      textAlign: TextAlign.center, style: TextStyle(color: hint)),
                  const SizedBox(height: 24),
                  TextField(enableIMEPersonalizedLearning: false, 
                    controller: _key,
                    autocorrect: false,
                    obscureText: true,
                    onSubmitted: (_) => _unlock(),
                    decoration: const InputDecoration(hintText: 'Секретная фраза'),
                  ),
                  if (_error != null) Padding(padding: const EdgeInsets.only(top: 10), child: Text(_error!, style: const TextStyle(color: Colors.redAccent))),
                  const SizedBox(height: 14),
                  FilledButton(
                    onPressed: _busy ? null : _unlock,
                    style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(50)),
                    child: _busy ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white)) : const Text('Подтвердить'),
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

/// Подтвердить собеседника сравнением эмодзи (оба должны быть в сети).
Future<void> verifyUser(BuildContext context, String userId) async {
  try {
    await client.updateUserDeviceKeys(additionalUsers: {userId});
    final list = client.userDeviceKeys[userId];
    if (list == null) throw StateError('no keys');
    final req = await list.startVerification();
    if (!context.mounted) return;
    await showVerificationDialog(context, req);
    if (Trust.instance.userVerified(userId)) await Trust.instance.acceptChange(userId);
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Не удалось начать подтверждение — собеседник должен быть в сети')));
    }
  }
}
