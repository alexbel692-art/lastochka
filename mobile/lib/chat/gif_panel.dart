// Вкладка «GIF» в панели эмодзи и стикеров: «Мои GIF» и поиск GIPHY.
import 'dart:async';

import 'package:flutter/material.dart';

import '../system/perf.dart' show remoteSession;
import '../widgets/mxc_image.dart';
import 'gifs.dart';

class GifTab extends StatefulWidget {
  final void Function(SavedGif g) onSaved;
  final void Function(GifResult g) onFound;
  const GifTab({super.key, required this.onSaved, required this.onFound});
  @override
  State<GifTab> createState() => _GifTabState();
}

class _GifTabState extends State<GifTab> {
  final _q = TextEditingController();
  Timer? _debounce;
  bool _search = false; // поиск доступен (есть ключ и не выключен)
  bool _loading = false;
  String? _error;
  List<GifResult> _found = const [];
  int _gen = 0;

  @override
  void initState() {
    super.initState();
    () async {
      final on = await gifSearchOn() && (await giphyKey()).isNotEmpty;
      if (!mounted) return;
      setState(() => _search = on);
      if (on) _run();
    }();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _q.dispose();
    super.dispose();
  }

  Future<void> _run() async {
    final gen = ++_gen;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final r = await searchGifs(_q.text);
      if (!mounted || gen != _gen) return;
      setState(() => _found = r);
    } catch (_) {
      if (mounted && gen == _gen) setState(() => _error = 'GIPHY не отвечает — проверьте подключение или ключ');
    } finally {
      if (mounted && gen == _gen) setState(() => _loading = false);
    }
  }

  Future<void> _remove(SavedGif g) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('Убрать из «Моих GIF»?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Отмена')),
          FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('Убрать')),
        ],
      ),
    );
    if (ok == true) {
      await removeSavedGif(g.url);
      if (mounted) setState(() {});
    }
  }

  Widget _badge(Widget child) => Stack(fit: StackFit.expand, children: [
        child,
        Positioned(
          left: 4,
          bottom: 4,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
            decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(4)),
            child: const Text('GIF', style: TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w700)),
          ),
        ),
      ]);

  @override
  Widget build(BuildContext context) {
    final hint = Theme.of(context).hintColor;
    final saved = savedGifs();
    final showSaved = _q.text.trim().isEmpty && saved.isNotEmpty;
    Widget title(String t) => Padding(padding: const EdgeInsets.fromLTRB(12, 8, 12, 4), child: Text(t, style: TextStyle(color: hint, fontSize: 13)));
    return CustomScrollView(slivers: [
      if (_search)
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 8, 10, 0),
            child: TextField(
              controller: _q,
              enableIMEPersonalizedLearning: false,
              decoration: InputDecoration(
                isDense: true,
                prefixIcon: const Icon(Icons.search, size: 20),
                hintText: 'Поиск GIF',
                suffixIcon: _loading ? const Padding(padding: EdgeInsets.all(12), child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))) : null,
              ),
              onChanged: (_) {
                _debounce?.cancel();
                _debounce = Timer(const Duration(milliseconds: 450), _run);
                setState(() {});
              },
            ),
          ),
        ),
      if (showSaved) ...[
        SliverToBoxAdapter(child: title('Мои GIF')),
        SliverGrid(
          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: 120, mainAxisSpacing: 4, crossAxisSpacing: 4),
          delegate: SliverChildListDelegate([
            for (final g in saved)
              InkWell(
                onTap: () => widget.onSaved(g),
                onLongPress: () => _remove(g),
                onSecondaryTap: () => _remove(g),
                child: ClipRRect(borderRadius: BorderRadius.circular(6), child: _badge(MxcImage(mxc: g.url, size: 200))),
              ),
          ]),
        ),
      ],
      if (!_search && saved.isEmpty)
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              'Здесь будут ваши GIF: в чате нажмите на GIF правой кнопкой или долго → «Сохранить GIF». '
              'Поиск GIF включается в «Настройки → GIF» (нужен ключ GIPHY).',
              style: TextStyle(color: hint, fontSize: 13),
            ),
          ),
        ),
      if (_search) ...[
        SliverToBoxAdapter(child: title(_q.text.trim().isEmpty ? 'Популярные' : 'Найдено')),
        if (_error != null) SliverToBoxAdapter(child: Padding(padding: const EdgeInsets.all(12), child: Text(_error!, style: TextStyle(color: hint)))),
        SliverGrid(
          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: 120, mainAxisSpacing: 4, crossAxisSpacing: 4),
          delegate: SliverChildListDelegate([
            for (final g in _found)
              InkWell(
                onTap: () => widget.onFound(g),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  // на удалённом рабочем столе — неподвижные превью: анимация рисуется процессором сервера
                  child: Image.network(remoteSession ? g.still : g.preview, fit: BoxFit.cover, gaplessPlayback: true,
                      errorBuilder: (_, __, ___) => const ColoredBox(color: Colors.black12)),
                ),
              ),
          ]),
        ),
        // условие GIPHY: подпись источника
        SliverToBoxAdapter(child: Padding(padding: const EdgeInsets.all(8), child: Center(child: Text('Powered by GIPHY', style: TextStyle(color: hint, fontSize: 11))))),
      ],
    ]);
  }
}
