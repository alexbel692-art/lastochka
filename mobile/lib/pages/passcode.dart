import 'package:flutter/material.dart';

import '../system/lock.dart';

/// Настройка код-пароля: включить, сменить, выключить, время автоблокировки, отпечаток.
class PasscodePage extends StatefulWidget {
  const PasscodePage({super.key});
  @override
  State<PasscodePage> createState() => _PasscodePageState();
}

class _PasscodePageState extends State<PasscodePage> {
  final lock = AppLock.instance;
  bool _bioAvail = false;

  @override
  void initState() {
    super.initState();
    lock.biometricAvailable().then((v) => mounted ? setState(() => _bioAvail = v) : null);
  }

  Future<bool> _confirmCurrent() async {
    final ok = await Navigator.of(context).push<bool>(MaterialPageRoute(
      builder: (c) => Scaffold(
        appBar: AppBar(),
        body: PinPad(
          title: 'Текущий код-пароль',
          length: lock.pinLength,
          onDone: (pin) async {
            if (await lock.check(pin)) {
              if (c.mounted) Navigator.pop(c, true);
              return null;
            }
            return 'Неверный код';
          },
        ),
      ),
    ));
    return ok == true;
  }

  Future<void> _setNew() async {
    String? first;
    final ok = await Navigator.of(context).push<bool>(MaterialPageRoute(
      builder: (c) => StatefulBuilder(
        builder: (c, set) => Scaffold(
          appBar: AppBar(),
          body: PinPad(
            title: first == null ? 'Придумайте код-пароль' : 'Повторите код-пароль',
            onDone: (pin) async {
              if (first == null) {
                set(() => first = pin);
                return null;
              }
              if (pin != first) {
                set(() => first = null);
                return 'Коды не совпали, попробуйте ещё раз';
              }
              await lock.setPin(pin);
              if (c.mounted) Navigator.pop(c, true);
              return null;
            },
          ),
        ),
      ),
    ));
    if (ok == true && mounted) {
      setState(() {});
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Код-пароль установлен')));
    }
  }

  Future<void> _setDuress() async {
    if (!await _confirmCurrent()) return;
    if (!mounted) return;
    final ok = await Navigator.of(context).push<bool>(MaterialPageRoute(
      builder: (c) => Scaffold(
        appBar: AppBar(),
        body: PinPad(
          title: 'Код для экстренного удаления',
          length: lock.pinLength,
          onDone: (pin) async {
            if (!await lock.setDuress(pin)) return 'Должен отличаться от обычного кода';
            if (c.mounted) Navigator.pop(c, true);
            return null;
          },
        ),
      ),
    ));
    if (ok == true && mounted) {
      setState(() {});
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Код для экстренного удаления задан')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final hint = Theme.of(context).hintColor;
    return Scaffold(
      appBar: AppBar(title: const Text('Код-пароль')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: ListView(children: [
            const SizedBox(height: 16),
            Icon(Icons.lock_outline, size: 64, color: Theme.of(context).colorScheme.primary),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                'Код-пароль защищает Ласточку отдельно от блокировки устройства. При включённом коде текст сообщений не показывается в уведомлениях.',
                textAlign: TextAlign.center,
                style: TextStyle(color: hint),
              ),
            ),
            if (!lock.enabled)
              ListTile(leading: const Icon(Icons.lock_open), title: const Text('Включить код-пароль'), onTap: _setNew)
            else ...[
              ListTile(
                leading: const Icon(Icons.password),
                title: const Text('Сменить код-пароль'),
                onTap: () async {
                  if (await _confirmCurrent()) await _setNew();
                },
              ),
              ListTile(
                leading: const Icon(Icons.timer_outlined),
                title: const Text('Автоблокировка'),
                subtitle: Text(lockTimeouts.firstWhere((t) => t.$1 == lock.timeout, orElse: () => lockTimeouts[1]).$2),
                onTap: () async {
                  final v = await showDialog<int>(
                    context: context,
                    builder: (d) => SimpleDialog(title: const Text('Блокировать, если Ласточка не на экране'), children: [
                      for (final (s, t) in lockTimeouts)
                        RadioListTile<int>(value: s, groupValue: lock.timeout, title: Text(t), onChanged: (v) => Navigator.pop(d, v)),
                    ]),
                  );
                  if (v != null) {
                    await lock.setTimeout(v);
                    setState(() {});
                  }
                },
              ),
              if (_bioAvail)
                SwitchListTile(
                  secondary: const Icon(Icons.fingerprint),
                  title: const Text('Разблокировка отпечатком / лицом'),
                  value: lock.biometric,
                  onChanged: (v) async {
                    await lock.setBiometric(v);
                    setState(() {});
                  },
                ),
              SwitchListTile(
                secondary: const Icon(Icons.delete_forever_outlined),
                title: const Text('Удалять данные после $wipeAfterFails ошибок'),
                subtitle: const Text('Если кто-то подбирает код — переписка на этом устройстве будет стёрта. На сервере и других устройствах она останется'),
                value: lock.wipeEnabled,
                onChanged: (v) async {
                  await lock.setWipe(v);
                  setState(() {});
                },
              ),
              ListTile(
                leading: const Icon(Icons.crisis_alert_outlined),
                title: Text(lock.duressEnabled ? 'Код для экстренного удаления — задан' : 'Код для экстренного удаления'),
                subtitle: const Text('Если вас заставят открыть Ласточку — введите этот код вместо обычного: данные на устройстве тихо удалятся, откроется экран входа'),
                trailing: lock.duressEnabled
                    ? IconButton(
                        tooltip: 'Убрать',
                        icon: const Icon(Icons.close),
                        onPressed: () async {
                          await lock.removeDuress();
                          setState(() {});
                        },
                      )
                    : null,
                onTap: _setDuress,
              ),
              ListTile(
                leading: const Icon(Icons.lock_reset, color: Colors.redAccent),
                title: const Text('Выключить код-пароль', style: TextStyle(color: Colors.redAccent)),
                onTap: () async {
                  if (!await _confirmCurrent()) return;
                  await lock.disable();
                  if (mounted) setState(() {});
                },
              ),
              ListTile(
                leading: const Icon(Icons.lock),
                title: const Text('Заблокировать сейчас'),
                onTap: () {
                  lock.locked.value = true;
                  Navigator.of(context).popUntil((r) => r.isFirst);
                },
              ),
            ],
          ]),
        ),
      ),
    );
  }
}
