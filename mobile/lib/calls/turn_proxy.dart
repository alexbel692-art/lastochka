// Посредник для сервера звонков (TURN), как в настольной Ласточке.
//
// Сервер звонков выдаёт ретранслятор без проверки логина и не подписывает ответы
// (нет MESSAGE-INTEGRITY), а модуль звонков WebRTC такие «успехи» молча выбрасывает.
// Посредник на 127.0.0.1 берёт проверку на себя: просит у WebRTC логин (401 + REALM/NONCE),
// убирает подпись из запроса к серверу и подписывает ответ сервера паролем TURN,
// который выдал сервер Matrix. Работает поверх TCP.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:matrix/matrix.dart';

const _magic = 0x2112A442;
const _realm = 'lastochka';
const _authAttrs = {0x0006, 0x0008, 0x001C, 0x0014, 0x0015, 0x8028};

final _crcTable = () {
  final t = Uint32List(256);
  for (var n = 0; n < 256; n++) {
    var c = n;
    for (var k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
    }
    t[n] = c;
  }
  return t;
}();

int _crc32(List<int> b) {
  var c = 0xFFFFFFFF;
  for (final x in b) {
    c = _crcTable[(c ^ x) & 0xff] ^ (c >> 8);
  }
  return (c ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}

int _u16(List<int> b, int i) => (b[i] << 8) | b[i + 1];
int _u32(List<int> b, int i) => (b[i] << 24) | (b[i + 1] << 16) | (b[i + 2] << 8) | b[i + 3];
List<int> _be16(int v) => [(v >> 8) & 0xff, v & 0xff];
List<int> _be32(int v) => [(v >> 24) & 0xff, (v >> 16) & 0xff, (v >> 8) & 0xff, v & 0xff];

class _Stun {
  final int method, cls;
  final List<int> txid;
  final List<(int, List<int>)> attrs;
  _Stun(this.method, this.cls, this.txid, this.attrs);

  static _Stun? parse(List<int> b) {
    if (b.length < 20 || (b[0] >> 6) != 0 || _u32(b, 4) != _magic) return null;
    final t = _u16(b, 0), len = _u16(b, 2);
    if (b.length < 20 + len) return null;
    final method = (t & 0x000F) | ((t & 0x00E0) >> 1) | ((t & 0x3E00) >> 2);
    final cls = ((t & 0x0100) >> 7) | ((t & 0x0010) >> 4);
    final attrs = <(int, List<int>)>[];
    var j = 20;
    while (j + 4 <= 20 + len) {
      final at = _u16(b, j), al = _u16(b, j + 2);
      if (j + 4 + al > b.length) break;
      attrs.add((at, b.sublist(j + 4, j + 4 + al)));
      j += 4 + al + ((4 - al % 4) % 4);
    }
    return _Stun(method, cls, b.sublist(8, 20), attrs);
  }

  static Uint8List build(int method, int cls, List<int> txid, Iterable<(int, List<int>)> attrs, [List<int>? key]) {
    final body = <int>[];
    for (final (t, v) in attrs) {
      body..addAll(_be16(t))..addAll(_be16(v.length))..addAll(v)..addAll(List.filled((4 - v.length % 4) % 4, 0));
    }
    final type = (method & 0x000F) | ((method & 0x0070) << 1) | ((method & 0x0F80) << 2) | ((cls & 1) << 4) | ((cls & 2) << 7);
    final head = <int>[..._be16(type), 0, 0, ..._be32(_magic), ...txid];
    var msg = <int>[];
    if (key != null) {
      final h = [...head]..setRange(2, 4, _be16(body.length + 24));
      final mac = Hmac(sha1, key).convert([...h, ...body]).bytes;
      msg = [...h, ...body, ..._be16(0x0008), ..._be16(20), ...mac];
    } else {
      msg = [...head, ...body]..setRange(2, 4, _be16(body.length));
    }
    msg.setRange(2, 4, _be16(msg.length - 20 + 8));
    final fp = (_crc32(msg) ^ 0x5354554e) & 0xFFFFFFFF;
    return Uint8List.fromList([...msg, ..._be16(0x8028), ..._be16(4), ..._be32(fp)]);
  }
}

/// Одно соединение WebRTC ↔ сервер звонков.
class _Shim {
  final Map<String, String> creds;
  String user = '';
  final String nonce = List.generate(12, (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0')).join();
  _Shim(this.creds);

  List<int>? _key(String u) {
    final pass = creds[u];
    return pass == null ? null : md5.convert(utf8.encode('$u:$_realm:$pass')).bytes;
  }

  /// Запрос от WebRTC: либо ответить самим (401), либо переслать на сервер.
  void up(List<int> msg, void Function(List<int>) reply, void Function(List<int>) forward) {
    final m = _Stun.parse(msg);
    if (m == null || m.cls != 0) return forward(msg);
    final hasMI = m.attrs.any((a) => a.$1 == 0x0008);
    if (!hasMI) {
      if (m.method == 3 && creds.isNotEmpty) {
        final err = [0, 0, 4, 1, ...utf8.encode('Unauthorized')];
        return reply(_Stun.build(3, 3, m.txid, [(0x0009, err), (0x0014, utf8.encode(_realm)), (0x0015, utf8.encode(nonce))]));
      }
      return forward(msg);
    }
    for (final a in m.attrs) {
      if (a.$1 == 0x0006) user = utf8.decode(a.$2, allowMalformed: true);
    }
    forward(_Stun.build(m.method, m.cls, m.txid, m.attrs.where((a) => !_authAttrs.contains(a.$1))));
  }

  /// Ответ сервера: подписать для WebRTC.
  List<int> down(List<int> msg) {
    final m = _Stun.parse(msg);
    if (m == null || (m.cls != 2 && m.cls != 3) || user.isEmpty) return msg;
    final key = _key(user);
    if (key == null) return msg;
    return _Stun.build(m.method, m.cls, m.txid, m.attrs.where((a) => !_authAttrs.contains(a.$1)), key);
  }
}

/// Нарезка TCP-потока на кадры STUN / ChannelData.
class _Framer {
  final void Function(List<int>) onFrame;
  List<int> _buf = [];
  _Framer(this.onFrame);

  void add(List<int> d) {
    _buf = _buf.isEmpty ? List.of(d) : (_buf..addAll(d));
    while (_buf.length >= 4) {
      final kind = _buf[0] >> 6;
      int total;
      if (kind == 0) {
        if (_buf.length < 20) break;
        total = 20 + _u16(_buf, 2);
      } else if (kind == 1) {
        final l = _u16(_buf, 2);
        total = 4 + l + ((4 - l % 4) % 4);
      } else {
        onFrame(_buf);
        _buf = [];
        break;
      }
      if (_buf.length < total) break;
      final one = _buf.sublist(0, total);
      _buf = _buf.sublist(total);
      onFrame(one);
    }
  }
}

class TurnProxy {
  TurnProxy._();
  static final instance = TurnProxy._();

  ServerSocket? _server;
  InternetAddress? _ip;
  int _port = 3478;
  String _host = '';
  final Map<String, String> _creds = {};

  int? get port => _server?.port;

  /// Адреса телефона: WebRTC привязывает сокеты к сетевому адаптеру,
  /// поэтому посредник доступен и по ним, а не только по 127.0.0.1.
  Future<List<String>> addresses() async {
    final out = ['127.0.0.1'];
    try {
      for (final i in await NetworkInterface.list(type: InternetAddressType.IPv4)) {
        for (final a in i.addresses) {
          if (!a.isLoopback) out.add(a.address);
        }
      }
    } catch (_) {}
    return out;
  }

  Future<bool> _own(InternetAddress a) async => a.isLoopback || (await addresses()).contains(a.address);

  /// Отвечает ли сервер звонков по TCP (запрос Binding).
  static Future<bool> probe(String host, int port) async {
    Socket? s;
    try {
      s = await Socket.connect(host, port, timeout: const Duration(seconds: 4));
      final req = [0, 1, 0, 0, ..._be32(_magic), ...List.generate(12, (_) => Random.secure().nextInt(256))];
      s.add(req);
      await s.first.timeout(const Duration(seconds: 4));
      return true;
    } catch (_) {
      return false;
    } finally {
      s?.destroy();
    }
  }

  /// Запускает посредника к серверу звонков [host]:[port] (если ещё не запущен) и запоминает логин.
  Future<int?> ensure(String host, int port, String user, String pass) async {
    if (user.isNotEmpty) {
      _creds[user] = pass;
      while (_creds.length > 8) {
        _creds.remove(_creds.keys.first);
      }
    }
    if (_server != null && _host == host && _port == port) return _server!.port;
    await _server?.close();
    _server = null;
    final ips = await InternetAddress.lookup(host, type: InternetAddressType.IPv4);
    if (ips.isEmpty) return null;
    _ip = ips.first;
    _host = host;
    _port = port;
    final server = await ServerSocket.bind(InternetAddress.anyIPv4, 0);
    server.listen(_handle, onError: (_) {});
    _server = server;
    Logs().i('[Ласточка] посредник звонков: 127.0.0.1:${server.port} → $host:$port');
    return server.port;
  }

  Future<void> _handle(Socket sock) async {
    if (!await _own(sock.remoteAddress)) {
      sock.destroy();
      return;
    }
    Socket up;
    try {
      up = await Socket.connect(_ip!, _port, timeout: const Duration(seconds: 8));
    } catch (_) {
      sock.destroy();
      return;
    }
    sock.setOption(SocketOption.tcpNoDelay, true);
    up.setOption(SocketOption.tcpNoDelay, true);
    final shim = _Shim(_creds);
    void end() {
      sock.destroy();
      up.destroy();
    }

    final fUp = _Framer((f) => shim.up(f, sock.add, up.add));
    final fDown = _Framer((f) => sock.add(shim.down(f)));
    sock.listen(fUp.add, onError: (_) => end(), onDone: end, cancelOnError: true);
    up.listen(fDown.add, onError: (_) => end(), onDone: end, cancelOnError: true);
  }
}

/// Добавляет к списку серверов звонков посредника на телефоне.
/// [servers] — список в формате WebRTC: {urls, username, credential}.
Future<List<Map<String, dynamic>>> withTurnProxy(List<Map<String, dynamic>> servers) async {
  try {
    for (final s in servers) {
      final urls = (s['urls'] is List ? s['urls'] as List : [s['urls'] ?? s['url']]).whereType<String>();
      for (final u in urls) {
        final m = RegExp(r'^turn:([^?:]+)(?::(\d+))?', caseSensitive: false).firstMatch(u);
        if (m == null) continue;
        final host = m.group(1)!, port = int.tryParse(m.group(2) ?? '') ?? 3478;
        if (!await TurnProxy.probe(host, port)) continue;
        final user = '${s['username'] ?? ''}', pass = '${s['credential'] ?? ''}';
        final p = await TurnProxy.instance.ensure(host, port, user, pass);
        if (p == null) continue;
        final addrs = await TurnProxy.instance.addresses();
        return [
          {'urls': [for (final a in addrs) 'turn:$a:$p?transport=tcp'], 'username': user, 'credential': pass},
          ...servers,
        ];
      }
    }
  } catch (e) {
    Logs().w('[Ласточка] посредник звонков не запущен', e);
  }
  return servers;
}
