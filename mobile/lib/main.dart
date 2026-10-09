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
import 'pages/settings.dart';
import 'system/lock.dart';
import 'system/desktop.dart';
import 'system/notify.dart';
import 'matrix_client.dart';
import 'pages/chats.dart';
import 'pages/login.dart';
import 'pages/verify.dart';
import 'theme.dart';

late Client client;
final navKey = GlobalKey<NavigatorState>();

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
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
  startAutodeleteSweeper();
  autoAcceptDirectInvites();
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
    return MaterialApp(
      title: 'Ласточка',
      debugShowCheckedModeBanner: false,
      navigatorKey: navKey,
      theme: lightTheme,
      darkTheme: darkTheme,
      themeMode: ThemeMode.system,
      locale: const Locale('ru'),
      supportedLocales: const [Locale('ru'), Locale('en')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: client.isLogged() ? const VerifyGate(child: ChatsPage()) : const LoginPage(),
      // код-пароль поверх всего приложения
      builder: (context, child) => ListenableBuilder(
        listenable: Listenable.merge([AppLock.instance.locked, callActive]),
        builder: (context, _) {
          // во время звонка экран звонка не закрываем блокировкой — иначе нельзя ответить
          final locked = AppLock.instance.locked.value && client.isLogged() && !callActive.value;
          return Stack(children: [
            ExcludeFocus(excluding: locked, child: child ?? const SizedBox.shrink()),
            if (locked)
              Positioned.fill(
                child: LockScreen(onForgot: () async {
                  await AppLock.instance.disable();
                  await logoutNow();
                }),
              ),
          ]);
        },
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
