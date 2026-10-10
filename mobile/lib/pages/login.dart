import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../main.dart';
import '../matrix_client.dart';
import 'chats.dart';
import 'verify.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});
  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _server = TextEditingController();
  final _user = TextEditingController();
  final _pass = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    SharedPreferences.getInstance().then((p) => setState(() => _server.text = p.getString('server') ?? ''));
  }

  Future<void> _login() async {
    var user = _user.text.trim();
    var server = _server.text.trim();
    // можно ввести логин целиком: @имя:сервер
    final m = RegExp(r'^@?([^:@\s]+):(\S+)$').firstMatch(user);
    if (m != null) {
      user = m.group(1)!;
      if (server.isEmpty) server = m.group(2)!;
    }
    if (server.isEmpty) return setState(() => _error = 'Укажите адрес сервера');
    if (user.isEmpty || _pass.text.isEmpty) return setState(() => _error = 'Введите логин и пароль');
    setState(() { _busy = true; _error = null; });
    try {
      final uri = server.startsWith('http') ? Uri.parse(server) : Uri.https(server, '');
      await client.checkHomeserver(uri);
      await client.login(
        LoginType.mLoginPassword,
        identifier: AuthenticationUserIdentifier(user: user),
        password: _pass.text,
        initialDeviceDisplayName: deviceLabel(),
      );
      (await SharedPreferences.getInstance()).setString('server', server);
      if (!mounted) return;
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const VerifyGate(child: ChatsPage())),
        (_) => false,
      );
    } on MatrixException catch (e) {
      setState(() => _error = e.errcode == 'M_FORBIDDEN' ? 'Неверный логин или пароль' : e.errorMessage);
    } catch (e) {
      setState(() => _error = 'Сервер недоступен или это не сервер Matrix');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 380),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Center(child: ClipRRect(borderRadius: BorderRadius.circular(26), child: Image.asset('assets/icon.png', width: 96, height: 96))),
                  const SizedBox(height: 16),
                  Text('Ласточка', textAlign: TextAlign.center, style: Theme.of(context).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 6),
                  Text('Защищённый мессенджер. Войдите в свой аккаунт Matrix', textAlign: TextAlign.center, style: TextStyle(color: Theme.of(context).hintColor)),
                  const SizedBox(height: 24),
                  TextField(enableIMEPersonalizedLearning: false, controller: _server, keyboardType: TextInputType.url, autocorrect: false, decoration: const InputDecoration(hintText: 'Адрес сервера, например matrix.org')),
                  const SizedBox(height: 10),
                  TextField(enableIMEPersonalizedLearning: false, controller: _user, autocorrect: false, decoration: const InputDecoration(hintText: 'Логин или @имя:сервер')),
                  const SizedBox(height: 10),
                  TextField(enableIMEPersonalizedLearning: false, controller: _pass, obscureText: true, onSubmitted: (_) => _login(), decoration: const InputDecoration(hintText: 'Пароль')),
                  if (_error != null) Padding(padding: const EdgeInsets.only(top: 10), child: Text(_error!, style: const TextStyle(color: Colors.redAccent))),
                  const SizedBox(height: 18),
                  FilledButton(
                    onPressed: _busy ? null : _login,
                    style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
                    child: _busy ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white)) : const Text('Войти', style: TextStyle(fontSize: 16)),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
