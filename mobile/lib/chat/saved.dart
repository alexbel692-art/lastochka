// «Избранное» — личный зашифрованный чат только с собой: заметки, пересланное себе, файлы.
// Какой чат — «Избранное», записано в данных аккаунта, поэтому он общий на всех ваших устройствах.
import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart';

import '../main.dart';

const savedType = 'ru.lastochka.saved';
const savedName = 'Избранное';

String? savedRoomId() {
  final id = client.accountData[savedType]?.content['room_id'];
  return id is String ? id : null;
}

bool isSaved(Room r) => r.id == savedRoomId();

/// Найти или создать «Избранное».
Future<Room?> openSaved() async {
  final id = savedRoomId();
  final existing = id == null ? null : client.getRoomById(id);
  if (existing != null && existing.membership == Membership.join) return existing;
  final newId = await client.createGroupChat(groupName: savedName, enableEncryption: true, preset: CreateRoomPreset.privateChat);
  final content = {'room_id': newId};
  await client.setAccountData(client.userID!, savedType, content);
  client.accountData[savedType] = BasicEvent(type: savedType, content: content);
  return client.getRoomById(newId) ?? await client.waitForRoomInSync(newId).then((_) => client.getRoomById(newId));
}

/// Значок «Избранного» вместо аватара.
class SavedAvatar extends StatelessWidget {
  final double size;
  const SavedAvatar({super.key, this.size = 54});
  @override
  Widget build(BuildContext context) => CircleAvatar(
        radius: size / 2,
        backgroundColor: Theme.of(context).colorScheme.primary,
        child: Icon(Icons.bookmark, color: Colors.white, size: size * 0.5),
      );
}
