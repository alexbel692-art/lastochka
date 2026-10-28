part of 'chat.dart';

// Непрочитанное при открытии чата (как в Telegram):
// • разделитель «Новые сообщения» над первым непрочитанным, и чат открывается на нём;
// • кнопка «@» — перейти к сообщениям, где вас упомянули, пока вы их не видели.
// Всё считается один раз — по состоянию на момент открытия, до отметки «прочитано».
extension _ChatUnread on _ChatPageState {
  Future<void> _findUnread(Timeline tl) async {
    if (_unreadDone) return;
    _unreadDone = true;
    if (_unreadAtOpen <= 0) return;
    final me = client.userID;
    bool others(Event e) => e.senderId != me && _visible(e) && memberText(e) == null;

    // отметка «прочитано до» может быть далеко в истории — догружаем немного, но не бесконечно
    for (var i = 0; i < 6 && mounted; i++) {
      final anchorLoaded = _readAnchor.isNotEmpty && tl.events.any((e) => e.eventId == _readAnchor);
      if (anchorLoaded || tl.events.where(others).length >= _unreadAtOpen || !tl.canRequestHistory) break;
      await _more();
    }
    if (!mounted) return;

    // новые — первыми; непрочитанные = новее отметки (или, если её не нашли, последние N чужих)
    final ai = _readAnchor.isEmpty ? -1 : tl.events.indexWhere((e) => e.eventId == _readAnchor);
    final unread = <Event>[];
    for (var i = 0; i < tl.events.length; i++) {
      final e = tl.events[i];
      if (ai >= 0 && i >= ai) break;
      if (!others(e)) continue;
      unread.add(e);
      if (ai < 0 && unread.length >= _unreadAtOpen) break;
    }
    if (unread.isEmpty) return;
    // в альбоме разделитель — над альбомом (первым показанным снимком)
    final (shown, albums) = groupAlbums(tl.events.where(_visible).toList());
    String head(Event e) {
      for (final MapEntry(key: id, value: list) in albums.entries) {
        if (list.any((x) => x.eventId == e.eventId)) return id;
      }
      return e.eventId;
    }

    final first = head(unread.last);
    final mentions = _mentionsAtOpen > 0 ? [for (final e in unread.reversed) if (_mentionsMe(e)) head(e)] : <String>[];
    _set(() {
      if (shown.any((e) => e.eventId == first)) _dividerBefore = first;
      _mentionIds = mentions.toSet().toList();
    });
  }

  bool _mentionsMe(Event e) {
    final me = client.userID;
    if (me == null) return false;
    final m = e.content.tryGetMap<String, Object?>('m.mentions');
    final ids = m?['user_ids'];
    if (ids is List && ids.contains(me)) return true;
    if (m?['room'] == true) return true;
    final html = e.content['formatted_body'];
    if (html is String && html.contains('matrix.to/#/$me')) return true;
    // старые клиенты без m.mentions: имя в тексте
    if (m == null) {
      final name = room.unsafeGetUserFromMemoryOrFallback(me).calcDisplayname();
      if (name.length >= 3 && e.body.toLowerCase().contains(name.toLowerCase())) return true;
    }
    return false;
  }

  Widget _mentionButton(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    final n = _mentionIds.length;
    return Tooltip(
      message: n == 1 ? 'К упоминанию' : 'К упоминанию (ещё $n)',
      child: Badge(
        isLabelVisible: n > 1,
        label: Text('$n'),
        backgroundColor: accent,
        child: FloatingActionButton.small(
          heroTag: null,
          backgroundColor: Theme.of(context).scaffoldBackgroundColor,
          foregroundColor: accent,
          onPressed: () {
            final id = _mentionIds.first;
            _set(() => _mentionIds = _mentionIds.sublist(1));
            _jumpTo(id);
          },
          child: const Text('@', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
        ),
      ),
    );
  }
}

/// Разделитель над первым непрочитанным сообщением.
class _UnreadDivider extends StatelessWidget {
  const _UnreadDivider();
  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.symmetric(vertical: 6),
        padding: const EdgeInsets.symmetric(vertical: 5),
        color: Colors.black.withValues(alpha: 0.16),
        alignment: Alignment.center,
        child: const Text('Новые сообщения', style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600)),
      );
}
