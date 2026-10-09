import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:matrix/encryption/utils/key_verification.dart';
import 'package:matrix/matrix.dart';

import 'calls/voip.dart';
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
  await initDesktop();
  client = await createClient();
  initVoip();
  await initNotifications();
  runApp(const LastochkaApp());
  // автозапуск с Windows — сразу в трей, без окна
  if (args.contains('--hidden')) {
    appVisible = false;
    WidgetsBinding.instance.addPostFrameCallback((_) => hideMainWindow());
  }
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
    await requestNotificationPermission();
    await startBackgroundService();
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
    );
  }
}
