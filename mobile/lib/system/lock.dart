// Код-пароль на вход в Ласточку (отдельно от блокировки телефона), с отпечатком/Face ID/Windows Hello.
// Хранится только хеш кода (PBKDF2-подобное многократное хеширование с солью).
import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../main.dart';
import 'notify.dart';

const lockTimeouts = [(0, 'Сразу'), (60, 'Через 1 минуту'), (300, 'Через 5 минут'), (900, 'Через 15 минут'), (3600, 'Через 1 час')];

/// После стольких неверных попыток подряд данные удаляются (если включено).
const wipeAfterFails = 10;

class AppLock {
  AppLock._();
  static final instance = AppLock._();

  final locked = ValueNotifier<bool>(false);
  SharedPreferences? _p;
  DateTime? _hiddenAt;
  /// Удалить все данные Ласточки на устройстве (задаётся при запуске).
  Future<void> Function()? onWipe;

  bool get enabled => (_p?.getString('lock.hash') ?? '').isNotEmpty;
  int get timeout => _p?.getInt('lock.timeout') ?? 60;
  bool get biometric => _p?.getBool('lock.bio') ?? true;
  int get pinLength => _p?.getInt('lock.len') ?? 4;
  // неудачные попытки хранятся на диске — перезапуск приложения счётчик не сбрасывает
  int get fails => _p?.getInt('lock.fails') ?? 0;
  DateTime? get blockedUntil {
    final ms = _p?.getInt('lock.blockedUntil');
    return ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms);
  }

  bool get wipeEnabled => _p?.getBool('lock.wipe') ?? false;
  bool get duressEnabled => (_p?.getString('lock.duress') ?? '').isNotEmpty;
  Future<void> setWipe(bool v) => _p!.setBool('lock.wipe', v);

  Future<void> init() async {
    _p = await SharedPreferences.getInstance();
    if (enabled) locked.value = true;
    visibility.addListener(_onVisibility);
  }

  void _onVisibility() {
    if (!enabled) return;
    if (!appVisible) {
      _hiddenAt ??= DateTime.now();
      if (timeout == 0) locked.value = true;
    } else {
      final h = _hiddenAt;
      _hiddenAt = null;
      if (h != null && DateTime.now().difference(h).inSeconds >= timeout) locked.value = true;
    }
  }

  static String _hash(String pin, String salt) {
    List<int> d = utf8.encode('$salt:$pin');
    for (var i = 0; i < 5000; i++) {
      d = sha256.convert([...d, ...utf8.encode(salt)]).bytes;
    }
    return base64.encode(d);
  }

  Future<void> setPin(String pin) async {
    final salt = base64.encode(List.generate(16, (_) => Random.secure().nextInt(256)));
    await _p!.setString('lock.salt', salt);
    await _p!.setString('lock.hash', _hash(pin, salt));
    await _p!.setInt('lock.len', pin.length);
    await _p!.remove('lock.duress'); // код экстренного удаления привязан к прежней «соли» — задаётся заново
  }

  Future<void> disable() async {
    for (final k in ['lock.hash', 'lock.salt', 'lock.duress', 'lock.fails', 'lock.blockedUntil', 'lock.wipe']) {
      await _p!.remove(k);
    }
    locked.value = false;
  }

  /// Код для экстренного удаления: при его вводе Ласточка тихо стирает все данные на устройстве.
  Future<bool> setDuress(String pin) async {
    final salt = _p!.getString('lock.salt') ?? '';
    final h = _hash(pin, salt);
    if (h == _p!.getString('lock.hash')) return false; // совпадает с обычным кодом
    await _p!.setString('lock.duress', h);
    return true;
  }

  Future<void> removeDuress() => _p!.remove('lock.duress');

  Future<void> setTimeout(int s) => _p!.setInt('lock.timeout', s);
  Future<void> setBiometric(bool v) => _p!.setBool('lock.bio', v);

  /// Проверить код. true — верный. Неверный — растущая пауза (30 с, 1, 2, 5, 15 минут…),
  /// а с включённым удалением после $wipeAfterFails ошибок подряд данные стираются.
  Future<bool> check(String pin, {bool allowDuress = true}) async {
    final until = blockedUntil;
    if (until != null && DateTime.now().isBefore(until)) return false;
    final h = _hash(pin, _p!.getString('lock.salt') ?? '');
    if (allowDuress && duressEnabled && h == _p!.getString('lock.duress')) {
      await onWipe?.call();
      return false;
    }
    final ok = h == _p!.getString('lock.hash');
    if (ok) {
      await _p!.remove('lock.fails');
      await _p!.remove('lock.blockedUntil');
      return true;
    }
    final n = fails + 1;
    await _p!.setInt('lock.fails', n);
    if (wipeEnabled && n >= wipeAfterFails) {
      await onWipe?.call();
      return false;
    }
    if (n >= 5) {
      const steps = [30, 60, 120, 300, 900];
      final sec = steps[(n - 5).clamp(0, steps.length - 1)];
      await _p!.setInt('lock.blockedUntil', DateTime.now().add(Duration(seconds: sec)).millisecondsSinceEpoch);
    }
    return false;
  }

  void unlock() {
    _hiddenAt = null; // окно отпечатка/Face ID ненадолго «прячет» приложение — это не повод снова блокировать
    locked.value = false;
  }

  final _auth = LocalAuthentication();

  Future<bool> biometricAvailable() async {
    try {
      return await _auth.isDeviceSupported() && await _auth.canCheckBiometrics;
    } catch (_) {
      return false;
    }
  }

  Future<bool> tryBiometric() async {
    if (!biometric || !await biometricAvailable()) return false;
    try {
      return await _auth.authenticate(localizedReason: 'Разблокировать Ласточку');
    } catch (_) {
      return false;
    }
  }
}

/// Экран ввода кода (и для разблокировки, и для установки нового кода).
class PinPad extends StatefulWidget {
  final String title;
  final int length;
  final Future<String?> Function(String pin) onDone; // вернуть текст ошибки или null
  final bool showBiometric;
  final Widget? footer;
  const PinPad({super.key, required this.title, required this.onDone, this.length = 4, this.showBiometric = false, this.footer});
  @override
  State<PinPad> createState() => _PinPadState();
}

class _PinPadState extends State<PinPad> with SingleTickerProviderStateMixin {
  String _pin = '';
  String? _error;
  final _keys = FocusNode();
  late final AnimationController _shake = AnimationController(vsync: this, duration: const Duration(milliseconds: 400));

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _keys.requestFocus();
      if (widget.showBiometric) _bio();
    });
  }

  @override
  void dispose() {
    _keys.dispose();
    _shake.dispose();
    super.dispose();
  }

  Future<void> _bio() async {
    if (await AppLock.instance.tryBiometric()) AppLock.instance.unlock();
  }

  Future<void> _tap(String d) async {
    if (_pin.length >= widget.length) return;
    HapticFeedback.selectionClick();
    setState(() {
      _pin += d;
      _error = null;
    });
    if (_pin.length == widget.length) {
      final err = await widget.onDone(_pin);
      if (!mounted) return;
      if (err != null) {
        HapticFeedback.heavyImpact();
        _shake.forward(from: 0);
        setState(() {
          _error = err;
          _pin = '';
        });
      } else {
        setState(() => _pin = '');
      }
    }
  }

  Widget _key(String d, {String? sub}) => SizedBox(
        width: 78,
        height: 78,
        child: Material(
          color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.08),
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: () => _tap(d),
            child: Center(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Text(d, style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w500)),
                if (sub != null) Text(sub, style: TextStyle(fontSize: 9, letterSpacing: 1.5, color: Theme.of(context).hintColor)),
              ]),
            ),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    return KeyboardListener(
      focusNode: _keys,
      autofocus: true,
      onKeyEvent: (e) {
        if (e is! KeyDownEvent) return;
        final c = e.character;
        if (c != null && RegExp(r'^\d$').hasMatch(c)) _tap(c);
        if (e.logicalKey == LogicalKeyboardKey.backspace && _pin.isNotEmpty) setState(() => _pin = _pin.substring(0, _pin.length - 1));
      },
      child: Center(
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            ClipRRect(borderRadius: BorderRadius.circular(20), child: Image.asset('assets/icon.png', width: 72, height: 72)),
            const SizedBox(height: 18),
            Text(widget.title, style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w600)),
            const SizedBox(height: 18),
            AnimatedBuilder(
              animation: _shake,
              builder: (_, child) => Transform.translate(offset: Offset(sin(_shake.value * pi * 6) * 12 * (1 - _shake.value), 0), child: child),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                for (var i = 0; i < widget.length; i++)
                  Container(
                    width: 14,
                    height: 14,
                    margin: const EdgeInsets.symmetric(horizontal: 8),
                    decoration: BoxDecoration(shape: BoxShape.circle, color: i < _pin.length ? accent : Colors.transparent, border: Border.all(color: accent, width: 1.6)),
                  ),
              ]),
            ),
            SizedBox(height: 28, child: Center(child: Text(_error ?? '', style: const TextStyle(color: Colors.redAccent)))),
            for (final row in const [
              [('1', ''), ('2', 'АБВГ'), ('3', 'ДЕЖЗ')],
              [('4', 'ИЙКЛ'), ('5', 'МНОП'), ('6', 'РСТУ')],
              [('7', 'ФХЦЧ'), ('8', 'ШЩЪЫ'), ('9', 'ЬЭЮЯ')],
            ])
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 7),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  for (final (d, s) in row) Padding(padding: const EdgeInsets.symmetric(horizontal: 12), child: _key(d, sub: s.isEmpty ? null : s)),
                ]),
              ),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 7),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                SizedBox(
                  width: 102,
                  child: widget.showBiometric ? IconButton(iconSize: 32, icon: Icon(Icons.fingerprint, color: accent), onPressed: _bio) : null,
                ),
                _key('0'),
                SizedBox(
                  width: 102,
                  child: IconButton(
                    iconSize: 26,
                    icon: Icon(Icons.backspace_outlined, color: Theme.of(context).hintColor),
                    onPressed: _pin.isEmpty ? null : () => setState(() => _pin = _pin.substring(0, _pin.length - 1)),
                  ),
                ),
              ]),
            ),
            if (widget.footer != null) widget.footer!,
          ]),
        ),
      ),
    );
  }
}

/// Экран блокировки поверх всего приложения.
class LockScreen extends StatefulWidget {
  final VoidCallback onForgot;
  const LockScreen({super.key, required this.onForgot});
  @override
  State<LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends State<LockScreen> {
  bool _bio = false, _forgot = false;

  @override
  void initState() {
    super.initState();
    AppLock.instance.biometricAvailable().then((v) => mounted ? setState(() => _bio = v && AppLock.instance.biometric) : null);
  }

  @override
  Widget build(BuildContext context) {
    final lock = AppLock.instance;
    if (_forgot) {
      return Material(
        color: Theme.of(context).scaffoldBackgroundColor,
        child: SafeArea(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(28),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  const Icon(Icons.lock_reset, size: 56, color: Colors.redAccent),
                  const SizedBox(height: 14),
                  const Text('Забыли код-пароль?', style: TextStyle(fontSize: 19, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 10),
                  Text('Сбросить код можно только выходом из аккаунта на этом устройстве. Потом войдите снова и подтвердите устройство ключом восстановления.',
                      textAlign: TextAlign.center, style: TextStyle(color: Theme.of(context).hintColor)),
                  const SizedBox(height: 22),
                  FilledButton(
                    style: FilledButton.styleFrom(backgroundColor: Colors.redAccent, minimumSize: const Size.fromHeight(48)),
                    onPressed: widget.onForgot,
                    child: const Text('Выйти из аккаунта'),
                  ),
                  const SizedBox(height: 8),
                  TextButton(onPressed: () => setState(() => _forgot = false), child: const Text('Назад к вводу кода')),
                ]),
              ),
            ),
          ),
        ),
      );
    }
    return Material(
      color: Theme.of(context).scaffoldBackgroundColor,
      child: SafeArea(
        child: PinPad(
          key: ValueKey(_bio),
          title: 'Введите код-пароль',
          length: lock.pinLength,
          showBiometric: _bio,
          onDone: (pin) async {
            final until = lock.blockedUntil;
            if (until != null && DateTime.now().isBefore(until)) {
              return 'Слишком много попыток. Подождите ${until.difference(DateTime.now()).inSeconds + 1} с';
            }
            if (await lock.check(pin)) {
              lock.unlock();
              return null;
            }
            if (!client.isLogged()) return null; // данные удалены
            final left = wipeAfterFails - lock.fails;
            if (lock.wipeEnabled && left <= 3) return 'Неверный код. Ещё $left — и данные будут удалены';
            final u = lock.blockedUntil;
            if (u != null && DateTime.now().isBefore(u)) return 'Неверный код. Следующая попытка через ${u.difference(DateTime.now()).inSeconds + 1} с';
            return 'Неверный код';
          },
          footer: TextButton(onPressed: () => setState(() => _forgot = true), child: const Text('Забыли код?')),
        ),
      ),
    );
  }
}
