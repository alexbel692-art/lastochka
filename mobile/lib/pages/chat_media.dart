part of 'chat.dart';

// Картинки в ленте и открытие вложений.
/// Скачать вложение и открыть системной программой.
Future<void> openAttachment(Event e, void Function(String) toast) async {
  try {
    toast('Загрузка…');
    final f = await e.downloadAndDecryptAttachment();
    // расшифрованная копия — во внутренней папке приложения; удаляется при следующем запуске
    final dir = await privateTemp();
    var name = (e.content.tryGet<String>('filename') ?? e.body).replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    name = name.replaceAll(RegExp(r'[\x00-\x1f]'), '').trim();
    if (name.length > 120) name = name.substring(name.length - 120);
    if (name.isEmpty || RegExp(r'^\.+$').hasMatch(name)) name = 'файл';
    final path = p.join(dir.path, name);
    await File(path).writeAsBytes(f.bytes, flush: true);
    final r = await OpenFilex.open(path);
    if (r.type != ResultType.done) toast('Нет программы, чтобы открыть этот файл');
  } catch (_) {
    toast('Не удалось скачать файл');
  }
}

final _images = Lru<String, Future<Uint8List?>>(60)..register();

class _Image extends StatefulWidget {
  final Event event;
  final bool sticker;
  final Size? box; // плитка альбома: точный размер, без скругления
  const _Image(this.event, {this.sticker = false, this.box});
  @override
  State<_Image> createState() => _ImageState();
}

/// Картинки больше этого размера без уменьшенной копии не загружаются сами — только по нажатию
/// (защита от «картинки-бомбы», которая забивает память и подвешивает приложение).
const _autoLoadLimit = 15 * 1024 * 1024;
final Set<String> _manualLoaded = {};

class _ImageState extends State<_Image> {
  Event get event => widget.event;
  bool get sticker => widget.sticker;
  Size? get box => widget.box;

  Future<Uint8List?> _load({bool full = false}) => _images.putIfAbsent('${event.eventId}$full', () async {
        try {
          final f = await event.downloadAndDecryptAttachment(getThumbnail: !full && event.hasThumbnail);
          return f.bytes;
        } catch (_) {
          return null;
        }
      });

  @override
  Widget build(BuildContext context) {
    final info = event.content.tryGetMap<String, Object?>('info');
    final w = (info?['w'] as num?)?.toDouble();
    final h = (info?['h'] as num?)?.toDouble();
    final size = (info?['size'] as num?)?.toInt() ?? 0;
    final maxW = box?.width ?? (sticker ? 170.0 : min(paneWidth(context) * 0.7, 400.0));
    final ratio = (w != null && h != null && w > 0 && h > 0) ? w / h : 1.0;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    // декодируем не больше, чем нужно для показа, — огромная картинка не съест память
    final decodeW = (maxW * dpr).ceil().clamp(64, 1600);
    // размер указывает отправитель: если не указан — тоже не грузим сами
    final big = !sticker && !event.hasThumbnail && (size <= 0 || size > _autoLoadLimit) && !_manualLoaded.contains(event.eventId);
    final fullW = (MediaQuery.sizeOf(context).width * dpr * 2).ceil().clamp(512, 4096);
    Widget frame(Widget child) => box != null
        ? SizedBox(width: box!.width, height: box!.height, child: child)
        : SizedBox(width: maxW, child: AspectRatio(aspectRatio: sticker ? 1 : ratio.clamp(0.5, 2.5), child: child));
    return GestureDetector(
      onTap: sticker
          ? null
          : big
              ? () => setState(() => _manualLoaded.add(event.eventId))
              : () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => Scaffold(
                      backgroundColor: Colors.black,
                      appBar: AppBar(backgroundColor: Colors.black, foregroundColor: Colors.white),
                      body: FutureBuilder<Uint8List?>(
                        future: _load(full: true),
                        builder: (_, s) => s.data == null
                            ? Center(child: s.connectionState == ConnectionState.done ? const Icon(Icons.broken_image_outlined, color: Colors.white) : const CircularProgressIndicator())
                            : InteractiveViewer(
                                maxScale: 6,
                                child: Center(
                                  child: Image.memory(s.data!, fit: BoxFit.contain, cacheWidth: fullW, errorBuilder: (_, __, ___) => const Icon(Icons.broken_image_outlined, color: Colors.white)),
                                ),
                              ),
                      ),
                    ),
                  )),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(sticker || box != null ? 0 : 13),
        child: frame(
            big
                ? Container(
                    color: Colors.black12,
                    alignment: Alignment.center,
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      const Icon(Icons.download_outlined, size: 32),
                      Text(size > 0 ? '${(size / 1048576).toStringAsFixed(0)} МБ — нажмите, чтобы загрузить' : 'Нажмите, чтобы загрузить', textAlign: TextAlign.center, style: const TextStyle(fontSize: 12.5)),
                    ]),
                  )
                : FutureBuilder<Uint8List?>(
                    future: _load(),
                    builder: (_, s) => s.data == null
                        ? Container(color: sticker ? Colors.transparent : Colors.black12, child: s.connectionState == ConnectionState.done ? const Icon(Icons.broken_image_outlined) : null)
                        : Image.memory(
                            s.data!,
                            fit: sticker ? BoxFit.contain : BoxFit.cover,
                            gaplessPlayback: true,
                            cacheWidth: decodeW,
                            errorBuilder: (_, __, ___) => const Icon(Icons.broken_image_outlined),
                          ),
                  ),
        ),
      ),
    );
  }
}

/// Альбом: сетка фото и видео (ряды по 1–3), по нажатию — просмотр снимка.
class _Album extends StatelessWidget {
  final List<Event> items;
  final double width;
  const _Album({required this.items, required this.width});

  @override
  Widget build(BuildContext context) {
    const gap = 2.0;
    final rows = albumRows(items.length);
    var i = 0;
    return ClipRRect(
      borderRadius: BorderRadius.circular(13),
      child: SizedBox(
        width: width,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          for (var r = 0; r < rows.length; r++)
            Padding(
              padding: EdgeInsets.only(top: r == 0 ? 0 : gap),
              child: Row(children: [
                for (var k = 0; k < rows[r]; k++)
                  () {
                    final e = items[i++];
                    final w = (width - gap * (rows[r] - 1)) / rows[r];
                    final h = rows[r] == 1 ? width * 0.62 : rows[r] == 2 ? w * 0.9 : w;
                    return Padding(
                      padding: EdgeInsets.only(left: k == 0 ? 0 : gap),
                      child: e.messageType == MessageTypes.Video
                          ? VideoPreview(
                              event: e,
                              maxWidth: w,
                              height: h,
                              radius: 0,
                              onOpen: () => openVideo(context, e, () => openAttachment(e, (s) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s))))),
                            )
                          : _Image(e, box: Size(w, h)),
                    );
                  }(),
              ]),
            ),
        ]),
      ),
    );
  }
}

