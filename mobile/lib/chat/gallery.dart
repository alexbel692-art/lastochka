// Лента последних фото и видео в меню «Прикрепить» (как в Telegram): отметить несколько и отправить альбомом.
// Только телефоны и планшеты; доступ к галерее спрашивается при первом открытии меню.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';

import '../system/lru.dart';
import 'album.dart';
import 'voice.dart' show fmtDur;

final bool galleryStripSupported = Platform.isAndroid || Platform.isIOS;

final _thumbs = Lru<String, Future<Uint8List?>>(120)..register();

class GalleryStrip extends StatefulWidget {
  /// Выбранные снимки по порядку отметки.
  final ValueNotifier<List<AssetEntity>> picked;
  const GalleryStrip({super.key, required this.picked});
  @override
  State<GalleryStrip> createState() => _GalleryStripState();
}

class _GalleryStripState extends State<GalleryStrip> {
  List<AssetEntity>? _items;
  bool _denied = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final ps = await PhotoManager.requestPermissionExtend();
      if (!ps.hasAccess) {
        if (mounted) setState(() => _denied = true);
        return;
      }
      final paths = await PhotoManager.getAssetPathList(
        onlyAll: true,
        type: RequestType.common,
        filterOption: FilterOptionGroup(orders: [const OrderOption(type: OrderOptionType.createDate, asc: false)]),
      );
      final list = paths.isEmpty ? <AssetEntity>[] : await paths.first.getAssetListPaged(page: 0, size: 60);
      if (mounted) setState(() => _items = list.where((a) => a.type == AssetType.image || a.type == AssetType.video).toList());
    } catch (_) {
      if (mounted) setState(() => _items = const []);
    }
  }

  void _toggle(AssetEntity a) {
    final l = List.of(widget.picked.value);
    if (l.any((x) => x.id == a.id)) {
      l.removeWhere((x) => x.id == a.id);
    } else {
      if (l.length >= maxAlbum) return;
      l.add(a);
    }
    widget.picked.value = l;
  }

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    if (_denied) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: TextButton.icon(
          onPressed: () => PhotoManager.openSetting(),
          icon: const Icon(Icons.photo_library_outlined),
          label: const Text('Разрешить доступ к фото'),
        ),
      );
    }
    final items = _items;
    return SizedBox(
      height: 96,
      child: items == null
          ? const Center(child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2)))
          : items.isEmpty
              ? Center(child: Text('В галерее пока нет фото', style: TextStyle(color: Theme.of(context).hintColor)))
              : ValueListenableBuilder<List<AssetEntity>>(
                  valueListenable: widget.picked,
                  builder: (_, picked, __) => ListView.separated(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 2),
                    itemCount: items.length,
                    separatorBuilder: (_, __) => const SizedBox(width: 6),
                    itemBuilder: (_, i) {
                      final a = items[i];
                      final n = picked.indexWhere((x) => x.id == a.id) + 1;
                      return GestureDetector(
                        onTap: () => _toggle(a),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(14),
                          child: SizedBox(
                            width: 96,
                            height: 96,
                            child: Stack(fit: StackFit.expand, children: [
                              FutureBuilder<Uint8List?>(
                                future: _thumbs.putIfAbsent(a.id, () => a.thumbnailDataWithSize(const ThumbnailSize.square(240))),
                                builder: (_, s) => s.data == null
                                    ? ColoredBox(color: Colors.black.withValues(alpha: 0.08))
                                    : Image.memory(s.data!, fit: BoxFit.cover, gaplessPlayback: true),
                              ),
                              AnimatedContainer(
                                duration: const Duration(milliseconds: 150),
                                color: n > 0 ? Colors.black.withValues(alpha: 0.25) : Colors.transparent,
                              ),
                              if (a.type == AssetType.video)
                                Positioned(
                                  left: 5,
                                  bottom: 5,
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                                    decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(8)),
                                    child: Text(fmtDur(a.duration * 1000), style: const TextStyle(color: Colors.white, fontSize: 11)),
                                  ),
                                ),
                              Positioned(
                                right: 5,
                                top: 5,
                                child: AnimatedContainer(
                                  duration: const Duration(milliseconds: 150),
                                  width: 24,
                                  height: 24,
                                  alignment: Alignment.center,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: n > 0 ? accent : Colors.black26,
                                    border: Border.all(color: Colors.white, width: 1.6),
                                  ),
                                  child: n > 0 ? Text('$n', style: const TextStyle(color: Colors.white, fontSize: 12.5, fontWeight: FontWeight.w700)) : null,
                                ),
                              ),
                            ]),
                          ),
                        ),
                      );
                    },
                  ),
                ),
    );
  }
}
