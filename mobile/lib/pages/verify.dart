// Подтверждение входа: новое устройство нужно подтвердить ключом восстановления
// или с другого своего устройства (сравнение эмодзи), как в настольной версии.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:matrix/encryption.dart';
import 'package:matrix/encryption/utils/key_verification.dart';
import 'package:matrix/matrix.dart';

import '../main.dart';
import '../system/trust.dart';
import 'settings.dart';
import '../system/clock.dart';
import '../system/diag.dart';
import '../system/phrase_strength.dart';

/// Проверка новой секретной фразы. null — подходит.
String? phraseProblem(String p1, String p2) {
  if (p1.length < 12) return 'Фраза слишком короткая — нужно не меньше 12 символов';
  if (phraseStrength(p1, login: client.userID?.localpart) == Strength.weak) {
    return 'Слишком простая фраза — такие подбирают за минуты. Возьмите 3–4 не связанных слова, например «кот лампа облако 7»';
  }
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
  Duration? _skew;

  @override
  void initState() {
    super.initState();
    clockSkew().then((d) => mounted ? setState(() => _skew = d) : null);
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
      // ключ, которым на самом деле зашифрована подпись устройств (а не просто «по умолчанию»)
      await enc.ssss.open(EventTypes.CrossSigningSelfSigning).unlock(keyOrPassphrase: input);
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

  /// «Забыли секретную фразу?» — новая фраза вместо старой, со сбросом ключей (после двух предупреждений).
  bool _resetting = false;

  Future<void> _forgot() async {
    final first = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        icon: const Icon(Icons.warning_amber_rounded, color: Colors.orange, size: 40),
        title: const Text('Забыли секретную фразу?'),
        content: const Text(
          'Если нет другого подтверждённого устройства и вы не помните фразу, можно начать заново: '
          'задать новую секретную фразу и новые ключи.\n\n'
          'Вся прежняя переписка в защищённых чатах станет недоступна — на этом и на всех новых устройствах. '
          'Другие ваши устройства нужно будет подтвердить заново, а собеседники увидят, что ваши ключи сменились.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Отмена')),
          TextButton(onPressed: () => Navigator.pop(d, true), child: const Text('Продолжить', style: TextStyle(color: Colors.redAccent))),
        ],
      ),
    );
    if (first != true || !mounted) return;
    final word = TextEditingController();
    final sure = await showDialog<bool>(
      context: context,
      builder: (d) => StatefulBuilder(
        builder: (d, set) => AlertDialog(
          title: const Text('Точно сбросить?'),
          content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Прежнюю переписку вернуть будет нельзя. Чтобы подтвердить, введите слово СБРОСИТЬ.'),
            const SizedBox(height: 12),
            TextField(
              controller: word,
              autofocus: true,
              autocorrect: false,
              enableIMEPersonalizedLearning: false,
              onChanged: (_) => set(() {}),
              decoration: const InputDecoration(hintText: 'СБРОСИТЬ'),
            ),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Отмена')),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
              onPressed: word.text.trim().toUpperCase() == 'СБРОСИТЬ' ? () => Navigator.pop(d, true) : null,
              child: const Text('Сбросить'),
            ),
          ],
        ),
      ),
    );
    if (sure == true && mounted) {
      Diag.add('Сброс секретной фразы и ключей начат пользователем');
      setState(() {
        _resetting = true;
        _setupError = null;
      });
    }
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
    final wipe = _resetting; // сброс: старые ключи, подпись устройств и резервную копию — заменить новыми
    if (wipe) Trust.instance.selfReset = true;
    client.encryption!.bootstrap(onUpdate: (bs) async {
      try {
        switch (bs.state) {
          case BootstrapState.askWipeSsss:
            bs.wipeSsss(wipe);
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
            bs.wipeOnlineKeyBackup(wipe);
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
      if (wipe) {
        Diag.add('Сброс выполнен: новая секретная фраза и ключи');
        await client.updateUserDeviceKeys();
      }
      _resetting = false;
      setState(() {});
    } catch (e) {
      if (wipe) Trust.instance.selfReset = false;
      Diag.err('Настройка защиты${wipe ? ' (сброс)' : ''}', e);
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
                Text(_resetting ? 'Новая секретная фраза' : 'Секретная фраза', textAlign: TextAlign.center, style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700)),
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
                PhraseMeter(controller: _p1, login: client.userID?.localpart),
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
                if (_resetting)
                  TextButton(onPressed: _setupRunning ? null : () => setState(() => _resetting = false), child: const Text('Отмена — я вспомнил фразу'))
                else
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
    if (needsSecuritySetup() || (_resetting && needsVerification())) return _setupScreen(context);
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
                  if (skewMatters(_skew))
                    Container(
                      margin: const EdgeInsets.only(bottom: 10),
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(color: Colors.orange.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(12)),
                      child: Text('Часы этого устройства ${skewText(_skew!)} — подтверждение с другого устройства не пройдёт. $fixClockHint Секретной фразой подтвердить можно и так.',
                          style: TextStyle(color: Colors.orange.shade900, fontSize: 13)),
                    ),
                  OutlinedButton.icon(
                    onPressed: _busy ? null : _otherDevice,
                    style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(50)),
                    icon: const Icon(Icons.devices_outlined),
                    label: const Text('С другого устройства'),
                  ),
                  const SizedBox(height: 10),
                  TextButton(onPressed: _busy ? null : _forgot, child: const Text('Забыли секретную фразу?')),
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
    if (req.canceled || req.state == KeyVerificationState.error) {
      body = _CancelInfo(code: req.canceledCode, reason: req.canceledReason);
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

/// Почему подтверждение отменилось — словами, а для m.timeout ещё и сверка часов.
class _CancelInfo extends StatefulWidget {
  final String? code, reason;
  const _CancelInfo({this.code, this.reason});
  @override
  State<_CancelInfo> createState() => _CancelInfoState();
}

class _CancelInfoState extends State<_CancelInfo> {
  Duration? _skew;

  @override
  void initState() {
    super.initState();
    Diag.add('Подтверждение отменено: ${widget.code} ${widget.reason ?? ''}');
    if (widget.code == 'm.timeout') clockSkew(fresh: true).then((d) => mounted ? setState(() => _skew = d) : null);
  }

  @override
  Widget build(BuildContext context) {
    final text = switch (widget.code) {
      'm.timeout' => 'Время ожидания истекло. Так бывает, если часы на одном из ваших устройств неправильные (разница больше 5 минут) '
          'или другое устройство не ответило за 10 минут — например, Ласточка на нём была закрыта.',
      'm.user' => 'Подтверждение отменили на другом устройстве.',
      'm.mismatched_sas' || 'm.key_mismatch' => 'Эмодзи не совпали — подтверждение остановлено. Если вы ничего не путали, кто-то может вмешиваться в соединение: смените пароль.',
      'm.accepted' => 'Запрос принят на другом вашем устройстве.',
      'm.unknown_method' || 'm.unknown_transaction' || 'm.unexpected_message' => 'Другое устройство не поддерживает этот способ подтверждения. Используйте секретную фразу.',
      'im.fluffychat.unknown_device' => 'Другое устройство пока не знает об этом — подождите минуту и попробуйте ещё раз.',
      _ => 'Подтверждение не удалось${widget.reason != null ? ' (${widget.reason})' : ''}.',
    };
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(text),
      if (widget.code == 'm.timeout') ...[
        const SizedBox(height: 10),
        Text(
          _skew == null
              ? 'Проверьте, что время на телефоне и компьютере выставлено автоматически.'
              : skewMatters(_skew)
                  ? 'На этом устройстве часы ${skewText(_skew!)}. $fixClockHint'
                  : 'На этом устройстве часы в порядке — проверьте время на другом устройстве и что Ласточка там открыта.',
          style: TextStyle(fontSize: 13, color: skewMatters(_skew) ? Colors.orange.shade800 : Theme.of(context).hintColor),
        ),
        const SizedBox(height: 8),
        Text('Самый простой путь — подтвердить секретной фразой: другое устройство для этого не нужно.', style: TextStyle(fontSize: 13, color: Theme.of(context).hintColor)),
      ],
    ]);
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
