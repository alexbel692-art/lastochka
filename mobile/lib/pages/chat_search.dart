part of 'chat.dart';

// Поиск в чате и плавающая дата при прокрутке.
extension _ChatSearch on _ChatPageState {
  // ---------- поиск по чату ----------
  List<String> _collectHits(String q) {
    final s = q.trim().toLowerCase();
    final tl = _tl;
    if (s.length < 2 || tl == null) return [];
    final events = tl.events.where(_visible);
    return [
      for (final e in events)
        if (memberText(e) == null && ttlChangeText(e) == null && !e.redacted && eventPreview(e, tl).toLowerCase().contains(s)) e.eventId,
    ];
  }

  void _runSearch(String q) {
    final hits = _collectHits(q);
    _set(() {
      _hits = hits;
      _hitIdx = 0;
    });
    if (hits.isNotEmpty) _jumpTo(hits.first);
    _searchDeep(q);
  }

  /// Как в Telegram: ищем по всей истории — в фоне подгружаем более старые сообщения
  /// (до ~15 страниц), счётчик совпадений растёт по мере загрузки.
  Future<void> _searchDeep(String q) async {
    _deepTimer?.cancel();
    if (q.trim().length < 2) return;
    _deepTimer = Timer(const Duration(milliseconds: 500), () async {
      final tl = _tl;
      if (tl == null || _searchingMore) return;
      _set(() => _searchingMore = true);
      for (var k = 0; k < 15 && tl.canRequestHistory && mounted && _searchCtl.text == q; k++) {
        await _more();
        if (!mounted) return;
        final hits = _collectHits(q);
        if (hits.length != _hits.length) _set(() => _hits = hits);
      }
      if (mounted) _set(() => _searchingMore = false);
    });
  }

  /// Список всех найденных сообщений — нажатие переходит к сообщению.
  Future<void> _showHits() async {
    final tl = _tl;
    if (tl == null || _hits.isEmpty) return;
    final q = _searchCtl.text.trim();
    final byId = {for (final e in _events) e.eventId: e};
    final id = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (c) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(c).height * 0.7),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text('Найдено: ${_hits.length}', style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
            ),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: _hits.length,
                itemBuilder: (_, i) {
                  final e = byId[_hits[i]];
                  if (e == null) return const SizedBox.shrink();
                  final who = e.senderFromMemoryOrFallback.calcDisplayname();
                  final text = eventPreview(e, tl);
                  final low = text.toLowerCase(), at = low.indexOf(q.toLowerCase());
                  // кусочек вокруг совпадения
                  final from = at > 30 ? at - 30 : 0;
                  final snippet = '${from > 0 ? '…' : ''}${text.substring(from)}';
                  return ListTile(
                    leading: Avatar(mxc: e.senderFromMemoryOrFallback.avatarUrl, name: who, size: 40),
                    title: Row(children: [
                      Expanded(child: Text(who, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600))),
                      Text(DateFormat('d MMM, HH:mm', 'ru').format(e.originServerTs), style: TextStyle(fontSize: 12, color: Theme.of(c).hintColor)),
                    ]),
                    subtitle: Text(snippet, maxLines: 2, overflow: TextOverflow.ellipsis),
                    onTap: () => Navigator.pop(c, e.eventId),
                  );
                },
              ),
            ),
          ]),
        ),
      ),
    );
    if (id == null) return;
    final i = _hits.indexOf(id);
    if (i >= 0) _set(() => _hitIdx = i);
    _jumpTo(id);
  }

  /// Перейти к следующему (+1, более старому) или предыдущему (−1) совпадению.
  Future<void> _hitStep(int d) async {
    if (_hits.isEmpty) return;
    var i = _hitIdx + d;
    if (i >= _hits.length) {
      // дальше — ищем в более старой истории
      final tl = _tl;
      if (tl == null || !tl.canRequestHistory || _searchingMore) return;
      _set(() => _searchingMore = true);
      final before = _hits.length;
      for (var k = 0; k < 5 && tl.canRequestHistory && _hits.length == before; k++) {
        await _more();
        if (!mounted) return;
        _set(() {});
        await Future.delayed(const Duration(milliseconds: 50));
        _hits = _collectHits(_searchCtl.text);
      }
      _set(() => _searchingMore = false);
      if (_hits.length == before) return;
      i = before;
    }
    if (i < 0) return;
    _set(() => _hitIdx = i);
    _jumpTo(_hits[i]);
  }

  void _closeSearch() {
    _deepTimer?.cancel();
    _searchCtl.clear();
    _set(() {
      _searching = false;
      _hits = [];
    });
  }

  Widget _searchBar(BuildContext context) {
    final q = _searchCtl.text.trim();
    return Material(
      color: Theme.of(context).scaffoldBackgroundColor,
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
        child: Row(children: [
          Expanded(
            child: Text(
              q.length >= 2 && _hits.isNotEmpty
                  ? '${_hitIdx + 1} из ${_hits.length}${_searchingMore ? ' · ищем дальше…' : ''}'
                  : _searchingMore
                  ? 'Ищем в истории…'
                  : q.length < 2
                      ? 'Введите хотя бы 2 буквы'
                      : _hits.isEmpty
                          ? 'Ничего не найдено'
                          : '${_hitIdx + 1} из ${_hits.length}${_tl?.canRequestHistory == true ? '+' : ''}',
              style: TextStyle(color: Theme.of(context).hintColor),
            ),
          ),
          if (_hits.isNotEmpty) IconButton(tooltip: 'Список найденного', icon: const Icon(Icons.format_list_bulleted_rounded), onPressed: _showHits),
          IconButton(tooltip: 'Раньше', icon: const Icon(Icons.keyboard_arrow_up), onPressed: q.length < 2 ? null : () => _hitStep(1)),
          IconButton(tooltip: 'Позже', icon: const Icon(Icons.keyboard_arrow_down), onPressed: _hitIdx > 0 ? () => _hitStep(-1) : null),
        ]),
      ),
    );
  }

  // ---------- плавающая дата ----------
  void _updateFloatDate() {
    final box = _listKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.attached) return;
    final top = box.localToGlobal(Offset.zero).dy;
    DateTime? best;
    var bestY = -1e9, minY = 1e9;
    DateTime? minDate;
    for (final e in _events) {
      final rb = _keys[e.eventId]?.currentContext?.findRenderObject() as RenderBox?;
      if (rb == null || !rb.attached) continue;
      final y = rb.localToGlobal(Offset.zero).dy - top;
      if (y <= 36 && y > bestY) {
        bestY = y;
        best = e.originServerTs;
      }
      if (y < minY) {
        minY = y;
        minDate = e.originServerTs;
      }
    }
    final d = best ?? minDate;
    if (d == null) return;
    _floatHide?.cancel();
    _floatHide = Timer(const Duration(milliseconds: 1400), () => mounted ? _set(() => _floatShow = false) : null);
    if (!_floatShow || _floatDate == null || !DateUtils.isSameDay(_floatDate, d)) {
      _set(() {
        _floatDate = d;
        _floatShow = _scroll.hasClients && _scroll.position.pixels > 40;
      });
    }
  }

}
