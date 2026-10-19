import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:matrix/encryption/utils/key_verification.dart';
import 'package:matrix/matrix.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'calls/voip.dart';
import 'calls/locked_call.dart';
import 'chat/autodelete.dart';
import 'chat/outbox.dart';
import 'chat/polls.dart' show startPollCloser;
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
import 'system/device_guard.dart';
import 'system/notify.dart';
import 'matrix_client.dart';
import 'pages/home.dart';
import 'pages/login.dart';
import 'pages/verify.dart';
import 'theme.dart';
import 'widgets/splash.dart';
import 'system/perf.dart';
import 'system/stale_sessions.dart';

late Client client;
final _switcherCover = ValueNotifier<bool>(false);
final navKey = GlobalKey<NavigatorState>();
final messengerKey = GlobalKey<ScaffoldMessengerState>();

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  Diag.init();
  unawaited(Diag.initTrail());
  // кэш картинок Flutter — не больше 80 МБ (по умолчанию 100), для слабых телефонов; на RDP-сервере
  // Ласточка запущена у каждого пользователя — там 32 МБ, чтобы 15 копий не съедали память сервера
  PaintingBinding.instance.imageCache.maximumSizeBytes = (remoteSession ? 32 : 80) << 20;
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
  // заставка сразу — пока открывается защищённое хранилище и подключается всё остальное
  final started = DateTime.now();
  runApp(const Root());
  await initializeDateFormatting('ru');
  final hidden = args.contains('--hidden');
  await initDesktop(hidden: hidden);
  await CertPinning.instance.init();
  await Appearance.instance.init();
  try {
    client = await createClient();
  } catch (e, st) {
    Diag.err('Хранилище не открылось', e, st);
    await showMainWindow();
    appReady.value = MaterialApp(
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
              const SizedBox(height: 20),
              // выход из тупика: локальные данные стираются, переписка загрузится с сервера после входа
              Builder(
                builder: (ctx) => OutlinedButton(
                  onPressed: () async {
                    final ok = await showDialog<bool>(
                      context: ctx,
                      builder: (d) => AlertDialog(
                        title: const Text('Начать заново на этом устройстве?'),
                        content: const Text('Локальная база Ласточки на этом устройстве будет удалена. После входа переписка загрузится с сервера; '
                            'старые зашифрованные сообщения откроются после подтверждения входа секретной фразой или с другого устройства.'),
                        actions: [
                          TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Отмена')),
                          TextButton(onPressed: () => Navigator.pop(d, true), child: const Text('Удалить и выйти', style: TextStyle(color: Colors.redAccent))),
                        ],
                      ),
                    );
                    if (ok != true) return;
                    await wipeLocalStorage();
                    exit(0);
                  },
                  child: const Text('Удалить данные на этом устройстве и войти заново'),
                ),
              ),
            ]),
          ),
        ),
      ),
    );
    SchedulerBinding.instance.scheduleForcedFrame();
    return;
  }
  Diag.watchClient(client);
  final secret = deviceSecret;
  if (secret != null) unawaited(Diag.attachKey(secret));
  initVoip();
  await initNotifications();
  await AppLock.instance.init();
  AppLock.instance.onWipe = wipeDevice;
  await initPrivacy();
  switcherCoverWanted = () => screenProtect.value || AppLock.instance.enabled;
  await initDeviceGuard();
  await Trust.instance.init();
  Trust.instance.onOwnIdentityReset = () => showSecurityNotification('Ключи вашего аккаунта сброшены', 'Если вы этого не делали — срочно смените пароль и проверьте «Мои сеансы». Устройства нужно будет подтвердить заново.');
  Trust.instance.onNewLogin = (name) => showSecurityNotification('Новый вход в ваш аккаунт', '$name. Если это не вы — завершите сеанс в «Настройки → Мои сеансы» и смените пароль.');
  startAutodeleteSweeper();
  startPollCloser();
  startOutbox();
  autoAcceptDirectInvites();
  handlePasswordConfirmations();
  // нашлась новая версия — сообщение внизу экрана (и уведомление, если Ласточка свёрнута)
  Updater.instance.onNewVersion = (u) {
    if (!appVisible) {
      showSecurityNotification('Доступна Ласточка ${u.version}', 'Откройте Ласточку, чтобы обновиться');
      return;
    }
    messengerKey.currentState?.showSnackBar(SnackBar(
      duration: const Duration(seconds: 12),
      content: Text('Доступна новая версия Ласточки — ${u.version}'),
      action: SnackBarAction(label: 'Обновить', onPressed: () => Updater.instance.install()),
    ));
  };
  Updater.instance.start();
  unawaited(Updater.instance.checkDowngrade());
  // прошлое обновление на Windows не встало — сказать человеку и записать причину в отчёт
  unawaited(Updater.instance.checkFailedInstall().then((msg) {
    if (msg == null) return;
    Future.delayed(const Duration(seconds: 3), () => messengerKey.currentState?.showSnackBar(
        SnackBar(content: Text(msg), duration: const Duration(seconds: 12))));
  }));
  await Drafts.instance.init();
  unawaited(Scheduler.instance.init());
  // заставка показывается хотя бы до конца анимации влёта
  final left = const Duration(milliseconds: 1100) - DateTime.now().difference(started);
  final onScreen = !hidden && (isDesktopOS || WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed);
  // на RDP-сервере заставку не задерживаем: каждый её кадр рисует процессор сервера
  if (onScreen && !remoteSession && left > Duration.zero) await Future.delayed(left);
  appReady.value = const LastochkaApp();
  // запуск в фоне (после перезагрузки, из трея): кадры не рисуются — дорисовываем принудительно,
  // иначе приложение (фоновая служба, подписки) не запустится, пока не откроют окно
  SchedulerBinding.instance.scheduleForcedFrame();
  debugPrint('LASTOCHKA_UI_READY');
  // Android может запустить Ласточку в фоне (после перезагрузки, фоновой службой) — окна нет
  if (!isDesktopOS) appVisible = WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
  // автозапуск с Windows — сразу в трей, без окна
  if (hidden) appVisible = false;
  if (!hidden) unawaited(wakeWindowOnStart());
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
      Diag.add('Входящий запрос подтверждения (${req.userId == client.userID ? 'своё устройство' : 'собеседник'})');
      // Ласточка свёрнута — уведомление, иначе запрос истечёт через 10 минут незамеченным
      if (!appVisible) {
        showSecurityNotification(req.userId == client.userID ? 'Подтверждение входа' : 'Запрос подтверждения',
            req.userId == client.userID ? 'Другое ваше устройство просит подтвердить вход — откройте Ласточку' : 'Собеседник просит сравнить эмодзи — откройте Ласточку');
      }
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
    // раз в неделю — не остались ли забытые входы на старых устройствах
    Future.delayed(const Duration(seconds: 15), checkStaleSessions);
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
      scaffoldMessengerKey: messengerKey,
      theme: liteTheme(lightTheme),
      darkTheme: liteTheme(darkTheme),
      themeMode: Appearance.instance.themeMode.value,
      locale: const Locale('ru'),
      supportedLocales: const [Locale('ru'), Locale('en')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: client.isLogged() ? const VerifyGate(child: HomeShell()) : const LoginPage(),
      // код-пароль поверх всего приложения
      builder: (context, child) => MediaQuery(
        // размер текста из «Оформления» поверх системного
        // в RDP-сеансе анимации выключены (кадры рисует процессор сервера)
        data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(MediaQuery.textScalerOf(context).scale(1) * Appearance.instance.textScale.value), disableAnimations: remoteSession || MediaQuery.of(context).disableAnimations),
        child: ListenableBuilder(
        listenable: Listenable.merge([AppLock.instance.locked, callActive, currentCall, screenProtect, _switcherCover, screenCaptured, CertPinning.instance.alert]),
        builder: (context, _) {
          // звонок блокировку не снимает (иначе позвонивший получал доступ ко всем чатам);
          // ответить, отклонить и завершить можно с панели поверх экрана блокировки
          final locked = AppLock.instance.locked.value && client.isLogged();
          final call = currentCall.value;
          return Stack(children: [
            // под блокировкой приложение недоступно ни клавиатуре, ни экранному диктору (TalkBack/VoiceOver)
            ExcludeSemantics(
              excluding: locked,
              child: ExcludeFocus(excluding: locked, child: TickerMode(enabled: !locked, child: child ?? const SizedBox.shrink())),
            ),
            // iPhone: в переключателе приложений и во время записи экрана / AirPlay вместо переписки — заставка
            if ((_switcherCover.value && (screenProtect.value || AppLock.instance.enabled) || screenCaptured.value && screenProtect.value) && !locked)
              Positioned.fill(child: ColoredBox(color: Theme.of(context).scaffoldBackgroundColor, child: Center(child: Image.asset('assets/icon.png', width: 96)))),
            if (CertPinning.instance.alert.value != null && !locked) Positioned.fill(child: KeyedSubtree(key: ValueKey('${CertPinning.instance.alert.value!.host}|${CertPinning.instance.alert.value!.got}'), child: _CertAlertScreen(CertPinning.instance.alert.value!))),
            if (locked)
              Positioned.fill(
                child: BlockSemantics(child: LockScreen(onForgot: () async {
                  await logoutNow(); // экран блокировки держится, пока данные не удалены
                  await AppLock.instance.disable();
                })),
              ),
            if (locked && call != null && callActive.value) Positioned(left: 0, right: 0, top: 0, child: LockedCallPanel(session: call)),
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
      // «личный» чат, который на деле группа (много участников или создал не пригласивший), — спрашиваем
      final creator = r.getState(EventTypes.RoomCreate)?.senderId;
      final joined = r.summary.mJoinedMemberCount ?? 0;
      if ((creator != null && creator != inviter) || joined > 1) continue;
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
                  onPressed: () => _confirm ? CertPinning.instance.trustNew(widget.a) : setState(() => _confirm = true),
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
