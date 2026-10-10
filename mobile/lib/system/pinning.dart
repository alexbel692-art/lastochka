// Привязка к сертификату сервера (для любого сервера Matrix, по принципу «доверие при первом входе»).
// При первом подключении Ласточка запоминает, какой удостоверяющий центр выдал сертификат сервера
// (например, «Let's Encrypt»). Дальше соединение с сертификатом от другого центра — поддельный
// сертификат, «прозрачный» прокси с перехватом, взломанный центр — обрывается ДО отправки запроса,
// так что пароль и ключ входа не уходят злоумышленнику. Обычное продление сертификата не мешает.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/io_client.dart';
import 'package:shared_preferences/shared_preferences.dart';

class CertAlert {
  final String host, expected, got;
  CertAlert(this.host, this.expected, this.got);
}

class CertPinning {
  CertPinning._();
  static final instance = CertPinning._();

  final alert = ValueNotifier<CertAlert?>(null);
  Map<String, String> _pins = {};
  final Set<String> _refused = {}; // «Не подключаться» — до перезапуска больше не спрашиваем
  SharedPreferences? _p;

  Future<void> init() async {
    _p = await SharedPreferences.getInstance();
    _pins = Map<String, String>.from(jsonDecode(_p!.getString('tls.pins') ?? '{}') as Map);
  }

  /// Кто выдал сертификат: организация удостоверяющего центра (без имени конкретного промежуточного).
  static String issuerOf(X509Certificate c) {
    final o = RegExp(r'(?:^|/|,\s*)O=([^/,]+)').firstMatch(c.issuer)?.group(1)?.trim();
    if (o != null && o.isNotEmpty) return o;
    return c.issuer.replaceAll(RegExp(r'/?CN=[^/,]+'), '').trim();
  }

  void _check(String host, X509Certificate? cert) {
    if (cert == null) throw const TlsException('Сервер не предъявил сертификат');
    final got = issuerOf(cert);
    final pinned = _pins[host];
    if (pinned == null) {
      _pins[host] = got; // первое подключение — запоминаем
      unawaited(_p?.setString('tls.pins', jsonEncode(_pins)));
      return;
    }
    if (pinned != got) {
      if (!_refused.contains('$host|$got')) alert.value = CertAlert(host, pinned, got);
      throw TlsException('Сертификат сервера $host выдан «$got», а раньше — «$pinned». Соединение прервано.');
    }
  }

  /// Пользователь уверен, что смена сертификата законна (сервер перешёл к другому центру).
  Future<void> trustNew() async {
    final a = alert.value;
    if (a == null) return;
    _pins[a.host] = a.got;
    await _p?.setString('tls.pins', jsonEncode(_pins));
    alert.value = null;
  }

  void dismiss() {
    final a = alert.value;
    if (a != null) _refused.add('${a.host}|${a.got}');
    alert.value = null;
  }

  Future<void> forget() async {
    _pins = {};
    await _p?.remove('tls.pins');
  }

  /// HTTP-клиент для всего общения с сервером Matrix: сертификат проверяется сразу после
  /// TLS-рукопожатия, до того как в соединение будет записан хотя бы байт запроса.
  IOClient httpClient() {
    final hc = HttpClient()
      ..connectionTimeout = const Duration(seconds: 30)
      ..idleTimeout = const Duration(seconds: 60)
      // соединение всегда напрямую: через прокси проверка сертификата была бы не того сервера
      ..findProxy = ((_) => 'DIRECT');
    hc.connectionFactory = (Uri uri, String? proxyHost, int? proxyPort) async {
      final port = uri.hasPort ? uri.port : (uri.scheme == 'https' ? 443 : 80);
      if (uri.scheme != 'https') {
        // без шифрования — только к своему компьютеру или в локальной сети (для отладки)
        final ip = InternetAddress.tryParse(uri.host);
        final local = uri.host == 'localhost' ||
            (ip != null && (ip.isLoopback || (ip.type == InternetAddressType.IPv4 && RegExp(r'^(10\.|192\.168\.|172\.(1[6-9]|2\d|3[01])\.)').hasMatch(ip.address))));
        if (!local) throw const TlsException('Ласточка подключается к серверам только по защищённому соединению (https)');
        return Socket.startConnect(uri.host, port);
      }
      final t = await SecureSocket.startConnect(uri.host, port);
      final checked = t.socket.then((s) {
        try {
          _check(uri.host, s.peerCertificate);
        } catch (_) {
          s.destroy();
          rethrow;
        }
        return s;
      });
      return ConnectionTask.fromSocket(checked, t.cancel);
    };
    return IOClient(hc);
  }
}
