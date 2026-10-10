import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:matrix/encryption/utils/key_verification.dart';
import 'package:matrix/matrix.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'calls/voip.dart';
import 'chat/autodelete.dart';
import 'chat/drafts.dart';
import 'system/appearance.dart';
import 'system/diag.dart';
import 'pages/settings.dart';
import 'system/lock.dart';
import 'system/pinning.dart';
import 'system/privacy.dart';
import 'system/trust.dart';
import 'system/updater.dart';
import 'system/desktop.dart';
import 'system/notify.dart';
import 'matrix_client.dart';
import 'pages/chats.dart';
import 'pages/login.dart';
import 'pages/verify.dart';
import 'theme.dart';

late Client client;
final _switcherCover = ValueNotifier<bool>(false);
final navKey = GlobalKey<NavigatorState>();

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  Diag.init();
  // кэш картинок Flutter — не больше 80 МБ (по умолчанию 100), для слабых телефонов
  PaintingBinding.instance.imageCache.maximumSizeBytes = 80 << 20;
  // Вместо серого экрана при ошибке — понятное сообщение и кнопка «Назад».
  ErrorWidget.builder = (details) => Material(
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
              const Icon(Icons.error_outline, size: 48, color: Colors.redAccent),
              const SizedBox(height: 12),
              const Text('Что-то пошло не так', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              Text(details.exceptionAsString(), textAlign: TextAlign.center, maxLines: 6, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, color: Colors.grey)),
              const SizedBox(height: 16),
              FilledButton(onPressed: () => navKey.currentState?.maybePop(), child: const Text('Назад')),
            ]),
          ),
        ),
      );
  await initializeDateFormatting('ru');
  final hidden = args.contains('--hidden');
  await initDesktop(hidden: hidden);
  await CertPinning.instance.init();
  await Appearance.instance.init();
  try {
    client = await createClient();
  } catch (e) {
    await showMainWindow();
    runApp(MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: lightTheme,
      darkTheme: darkTheme,
      home: Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.lock_outline, size: 56, color: Colors.redAccent),
              const SizedBox(height: 12),
              const Text('Ласточка не смогла открыть хранилище', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              Text('$e', textAlign: TextAlign.center),
            ]),
          ),
        ),
      ),
    ));
    return;
  }
  initVoip();
  await initNotifications();
  await AppLock.instance.init();
  AppLock.instance.onWipe = wipeDevice;
  await initPrivacy();
  await Trust.instance.init();
  Trust.instance.onOwnIdentityReset = () => showSecurityNotification('Ключи вашего аккаунта сброшены', 'Если вы этого не делали — срочно смените пароль и проверьте «Мои сеансы». Устройства нужно будет подтвердить заново.');
  Trust.instance.onNewLogin = (name) => showSecurityNotification('Новый вход в ваш аккаунт', '$name. Если это не вы — завершите сеанс в «Настройки → Мои сеансы» и смените пароль.');
  startAutodeleteSweeper();
  autoAcceptDirectInvites();
  handlePasswordConfirmations();
  Updater.instance.start();
  unawaited(Updater.instance.checkDowngrade());
  await Drafts.instance.init();
  unawaited(Scheduler.instance.init());
  runApp(const LastochkaApp());
  // Android может запустить Ласточку в фоне (после перезагрузки, фоновой службой) — окна нет
  if (!isDesktopOS) appVisible = WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
  // автозапуск с Windows — сразу в трей, без окна
  if (hidden) appVisible = false;
}

class LastochkaApp extends StatefulWidget {
  const LastochkaApp({super.key});
  @override
  State<LastochkaApp> createState() => _LastochkaAppState();
}

class _LastochkaAppState extends State<LastochkaApp> {
  StreamSubscription? _login, _verify;

  late final AppLifecycleListener _life;

  @override
  void initState() {
    super.initState();
    _life = AppLifecycleListener(onStateChange: (s) {
      if (Platform.isIOS) _switcherCover.value = s != AppLifecycleState.resumed;
      if (!isDesktopOS) appVisible = s == AppLifecycleState.resumed;
    });
    if (client.isLogged()) WidgetsBinding.instance.addPostFrameCallback((_) => _afterLogin());
    _login = client.onLoginStateChanged.stream.listen((s) {
      setState(() {});
      if (s == LoginState.loggedIn) _afterLogin();
      if (s == LoginState.loggedOut) stopBackgroundService();
    });
    // входящие запросы на подтверждение (с другого устройства или от собеседника)
    _verify = client.onKeyVerificationRequest.stream.listen((KeyVerification req) {
      final ctx = navKey.currentContext;
      if (ctx != null) showIncomingVerification(ctx, req);
    });
  }

  // после входа: разрешение на уведомления и фоновая служба (Android)
  Future<void> _afterLogin() async {
    if (!appVisible && !isDesktopOS) {
      await startBackgroundService();
      return;
    }
    await requestNotificationPermission();
    await startBackgroundService();
    if (Platform.isAndroid && !await isIgnoringBatteryOptimizations()) {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool('bg.batteryAsked') == true) return;
      await prefs.setBool('bg.batteryAsked', true);
      final ctx = navKey.currentContext;
      if (ctx == null || !ctx.mounted) return;
      final ok = await showDialog<bool>(
        context: ctx,
        builder: (d) => AlertDialog(
          title: const Text('Звонки при закрытом приложении'),
          content: const Text('Чтобы сообщения и звонки приходили, даже когда Ласточка закрыта, разрешите ей работать без ограничений батареи. Расход заряда почти не изменится.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Позже')),
            FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('Разрешить')),
          ],
        ),
      );
      if (ok == true) await requestIgnoreBatteryOptimizations();
    }
  }

  @override
  void dispose() {
    _life.dispose();
    _login?.cancel();
    _verify?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Appearance.instance.all,
      builder: (context, _) => _app(context),
    );
  }

  Widget _app(BuildContext context) {
    return MaterialApp(
      title: 'Ласточка',
      debugShowCheckedModeBanner: false,
      navigatorKey: navKey,
      theme: lightTheme,
      darkTheme: darkTheme,
      themeMode: Appearance.instance.themeMode.value,
      locale: const Locale('ru'),
      supportedLocales: const [Locale('ru'), Locale('en')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: client.isLogged() ? const VerifyGate(child: ChatsPage()) : const LoginPage(),
      // код-пароль поверх всего приложения
      builder: (context, child) => MediaQuery(
        // размер текста из «Оформления» поверх системного
        data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(MediaQuery.textScalerOf(context).scale(1) * Appearance.instance.textScale.value)),
        child: ListenableBuilder(
        listenable: Listenable.merge([AppLock.instance.locked, callActive, screenProtect, _switcherCover, CertPinning.instance.alert]),
        builder: (context, _) {
          // во время звонка экран звонка не закрываем блокировкой — иначе нельзя ответить
          final locked = AppLock.instance.locked.value && client.isLogged() && !callActive.value;
          return Stack(children: [
            ExcludeFocus(excluding: locked, child: child ?? const SizedBox.shrink()),
            // iPhone: в переключателе приложений вместо переписки — заставка
            if (_switcherCover.value && screenProtect.value && !locked)
              Positioned.fill(child: ColoredBox(color: Theme.of(context).scaffoldBackgroundColor, child: Center(child: Image.asset('assets/icon.png', width: 96)))),
            if (CertPinning.instance.alert.value != null && !locked) Positioned.fill(child: _CertAlertScreen(CertPinning.instance.alert.value!)),
            if (locked)
              Positioned.fill(
                child: LockScreen(onForgot: () async {
                  await logoutNow(); // экран блокировки держится, пока данные не удалены
                  await AppLock.instance.disable();
                }),
              ),
          ]);
        },
      ),
      ),
    );
  }
}

/// Личный чат от коллеги с вашего сервера принимается автоматически — собеседнику не нужно
/// ничего нажимать. Приглашения с чужих серверов и в группы по-прежнему спрашивают.
void autoAcceptDirectInvites() {
  final seen = <String>{};
  client.onSync.stream.listen((_) async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool('invites.autoAccept') == false) return;
    final myDomain = client.userID?.domain;
    for (final r in client.rooms.where((r) => r.membership == Membership.invite)) {
      if (!seen.add(r.id)) continue;
      final me = r.getState(EventTypes.RoomMember, client.userID!);
      final isDirect = me?.content['is_direct'] == true;
      final inviter = me?.senderId;
      if (!isDirect || inviter == null || inviter.domain != myDomain) continue;
      try {
        await r.join();
      } catch (_) {
        seen.remove(r.id); // попробуем при следующей синхронизации
      }
    }
  });
}

/// Сервер иногда просит подтвердить важное действие паролем (например, настройку защиты).
void handlePasswordConfirmations() {
  client.onUiaRequest.stream.listen((uia) async {
    if (uia.state != UiaRequestState.waitForUser) return;
    if (!uia.nextStages.contains(AuthenticationTypes.password)) return uia.cancel();
    final ctx = navKey.currentContext;
    if (ctx == null) return uia.cancel();
    final c = TextEditingController();
    final pw = await showDialog<String>(
      context: ctx,
      barrierDismissible: false,
      builder: (d) => AlertDialog(
        title: const Text('Подтвердите паролем'),
        content: TextField(enableIMEPersonalizedLearning: false, controller: c, obscureText: true, autofocus: true, decoration: const InputDecoration(hintText: 'Пароль от аккаунта'), onSubmitted: (v) => Navigator.pop(d, v)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d), child: const Text('Отмена')),
          FilledButton(onPressed: () => Navigator.pop(d, c.text), child: const Text('Подтвердить')),
        ],
      ),
    );
    if (pw == null || pw.isEmpty) return uia.cancel();
    await uia.completeStage(AuthenticationPassword(
      session: uia.session,
      password: pw,
      identifier: AuthenticationUserIdentifier(user: client.userID!),
    ));
  });
}

/// Сертификат сервера выдан не тем центром, что раньше — возможен перехват соединения.
/// (Экран лежит поверх навигации, поэтому подтверждение — прямо на нём, без диалогов.)
class _CertAlertScreen extends StatefulWidget {
  final CertAlert a;
  const _CertAlertScreen(this.a);
  @override
  State<_CertAlertScreen> createState() => _CertAlertScreenState();
}

class _CertAlertScreenState extends State<_CertAlertScreen> {
  bool _confirm = false;

  @override
  Widget build(BuildContext context) {
    final a = widget.a;
    return Material(
      color: Theme.of(context).scaffoldBackgroundColor,
      child: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(28),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 460),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                const Icon(Icons.gpp_bad, size: 64, color: Colors.red),
                const SizedBox(height: 14),
                const Text('Соединение с сервером может быть перехвачено', textAlign: TextAlign.center, style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
                const SizedBox(height: 12),
                Text(
                  _confirm
                      ? 'Нажимайте «Доверять», только если администратор подтвердил, что сервер ${a.host} теперь использует сертификат «${a.got}».'
                      : 'Сертификат сервера ${a.host} выдан «${a.got}», а раньше его выдавал «${a.expected}». '
                          'Так бывает, если кто-то подменяет соединение (поддельная сеть Wi-Fi, программа-перехватчик, атака на сервер). '
                          'Ласточка прервала соединение — ни пароль, ни сообщения не отправлены.\n\n'
                          'Если администратор сервера действительно сменил сертификат — уточните у него и только тогда доверяйте новому.',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 22),
                FilledButton(
                  style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                  onPressed: () => _confirm ? setState(() => _confirm = false) : CertPinning.instance.dismiss(),
                  child: Text(_confirm ? 'Назад' : 'Не подключаться'),
                ),
                const SizedBox(height: 8),
                TextButton(
                  onPressed: () => _confirm ? CertPinning.instance.trustNew() : setState(() => _confirm = true),
                  child: Text(_confirm ? 'Да, доверять новому сертификату' : 'Администратор подтвердил смену', style: const TextStyle(color: Colors.red)),
                ),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}
