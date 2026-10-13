// Показ фото и видео в ленте и аватаров в приглашениях — общая настройка Matrix (MSC4278),
// та же, что в Element X и Element Web: меняется в любом из клиентов и действует во всех.
import 'package:matrix/matrix.dart';

import '../main.dart';

class MediaPolicy {
  MediaPolicy._();

  static const _stable = 'm.media_preview_config';
  static const _unstable = 'io.element.msc4278.media_preview_config';

  static Map<String, Object?> get _cfg =>
      client.accountData[_stable]?.content ?? client.accountData[_unstable]?.content ?? const <String, Object?>{};

  /// «on» — везде, «private» — только в закрытых чатах (не публичных), «off» — нигде (по нажатию).
  static String get previews {
    final v = _cfg['media_previews'];
    return v == 'off' || v == 'private' ? v as String : 'on';
  }

  static bool get inviteAvatars => _cfg['invite_avatars'] != 'off';

  /// Показывать ли фото и видео сразу в этом чате. Свои — всегда.
  static bool showIn(Room room, {String? senderId}) {
    if (senderId != null && senderId == client.userID) return true;
    return switch (previews) {
      'off' => false,
      'private' => room.joinRules != JoinRules.public,
      _ => true,
    };
  }

  static Future<void> set({String? previews, bool? inviteAvatars}) async {
    final next = <String, Object?>{
      ..._cfg,
      if (previews != null) 'media_previews': previews,
      if (inviteAvatars != null) 'invite_avatars': inviteAvatars ? 'on' : 'off',
    };
    final me = client.userID!;
    await client.setAccountData(me, _stable, next);
    await client.setAccountData(me, _unstable, next);
  }
}
