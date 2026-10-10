// QR-коды: показать свой (или группы) и отсканировать чужой — чтобы начать чат или вступить в группу.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../main.dart';
import '../system/clipboard.dart';
import 'chat.dart';

final bool canScanQr = Platform.isAndroid || Platform.isIOS;

String userLink(String userId) => 'https://matrix.to/#/$userId';

String roomLink(Room r) {
  final alias = r.canonicalAlias;
  final id = alias.isNotEmpty ? alias : r.id;
  final via = client.userID?.domain;
  return 'https://matrix.to/#/$id${alias.isEmpty && via != null ? '?via=$via' : ''}';
}

Future<void> showQr(BuildContext context, String title, String link, {String? note}) => showDialog(
      context: context,
      builder: (d) => AlertDialog(
        title: Text(title, textAlign: TextAlign.center),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            color: Colors.white,
            padding: const EdgeInsets.all(12),
            child: QrImageView(data: link, size: 230, backgroundColor: Colors.white),
          ),
          const SizedBox(height: 10),
          SelectableText(link, textAlign: TextAlign.center, style: const TextStyle(fontSize: 12.5)),
          if (note != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(note, textAlign: TextAlign.center, style: TextStyle(fontSize: 12.5, color: Theme.of(d).hintColor))),
        ]),
        actions: [
          TextButton(
            onPressed: () async {
              await copySensitive(link, clearAfter: const Duration(minutes: 5));
              if (d.mounted) Navigator.pop(d);
            },
            child: const Text('Скопировать ссылку'),
          ),
          FilledButton(onPressed: () => Navigator.pop(d), child: const Text('Готово')),
        ],
      ),
    );

/// Сканер QR-кода. Возвращает прочитанный текст.
Future<String?> scanQr(BuildContext context) => Navigator.of(context).push<String>(MaterialPageRoute(builder: (_) => const _ScanPage()));

class _ScanPage extends StatefulWidget {
  const _ScanPage();
  @override
  State<_ScanPage> createState() => _ScanPageState();
}

class _ScanPageState extends State<_ScanPage> {
  bool _done = false;
  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(backgroundColor: Colors.black, foregroundColor: Colors.white, title: const Text('Наведите на QR-код')),
        body: MobileScanner(
          onDetect: (capture) {
            if (_done) return;
            final v = capture.barcodes.map((b) => b.rawValue).whereType<String>().firstOrNull;
            if (v == null) return;
            _done = true;
            Navigator.of(context).pop(v);
          },
        ),
      );
}

/// Ссылка matrix.to (или @id / #адрес) → начать чат или вступить в группу (после подтверждения).
Future<void> openMatrixLink(BuildContext context, String text) async {
  var id = text.trim();
  final m = RegExp(r'matrix\.to/#/([^?\s]+)').firstMatch(id);
  if (m != null) id = Uri.decodeComponent(m[1]!);
  void toast(String s) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s)));
  if (!RegExp(r'^[@#!][^\s:]+:[A-Za-z0-9.\-:]+$').hasMatch(id)) return toast('Это не QR-код Matrix');
  final isUser = id.startsWith('@');
  if (isUser && id == client.userID) return toast('Это ваш собственный код');
  final ok = await showDialog<bool>(
    context: context,
    builder: (d) => AlertDialog(
      title: Text(isUser ? 'Начать чат?' : 'Вступить в группу?'),
      content: Text(id),
      actions: [
        TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Отмена')),
        FilledButton(onPressed: () => Navigator.pop(d, true), child: Text(isUser ? 'Написать' : 'Вступить')),
      ],
    ),
  );
  if (ok != true) return;
  try {
    final roomId = isUser ? await client.startDirectChat(id, enableEncryption: true) : await client.joinRoom(id);
    final room = client.getRoomById(roomId) ?? await client.waitForRoomInSync(roomId).then((_) => client.getRoomById(roomId));
    if (room != null && context.mounted) Navigator.of(context).push(MaterialPageRoute(builder: (_) => ChatPage(room: room)));
  } on MatrixException catch (e) {
    toast(e.errcode == 'M_FORBIDDEN' ? 'Нет доступа: в эту группу входят только по приглашению' : e.errorMessage);
  } catch (_) {
    toast('Не получилось');
  }
}
