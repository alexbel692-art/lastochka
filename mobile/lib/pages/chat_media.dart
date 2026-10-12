part of 'chat.dart';

// Картинки в ленте и открытие вложений.
/// Скачать вложение и открыть системной программой.
/// Программы и скрипты не открываются сами — только сохраняются с предупреждением.
Future<void> openAttachment(Event e, void Function(String) toast, {BuildContext? context}) async {
  try {
    toast('Загрузка…');
    final f = await e.downloadAndDecryptAttachment();
    var name = (e.content.tryGet<String>('filename') ?? e.body).replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    name = name.replaceAll(RegExp(r'[\x00-\x1f\u202a-\u202e\u2066-\u2069]'), '').trim(); // без «переворота» текста: «txt.exe» → «exe.txt»
    if (name.length > 120) name = name.substring(name.length - 120);
    if (name.isEmpty || RegExp(r'^\.+$').hasMatch(name)) name = 'файл';
    final danger = isDangerousFile(name);
    // на компьютере — сразу в «Загрузки» (как в Telegram Desktop), на телефоне — во внутреннюю
    // папку приложения (удаляется при следующем запуске)
    final downloads = isDesktop ? await getDownloadsDirectory() : null;
    final dir = downloads ?? await privateTemp();
    var path = p.join(dir.path, name);
    if (downloads != null) {
      // файл с таким именем уже есть — «имя (1).pdf», «имя (2).pdf»…
      final dot = name.lastIndexOf('.');
      final base = dot > 0 ? name.substring(0, dot) : name, ext = dot > 0 ? name.substring(dot) : '';
      for (var i = 1; File(path).existsSync() && i < 1000; i++) {
        path = p.join(dir.path, '$base ($i)$ext');
      }
    }
    await File(path).writeAsBytes(f.bytes, flush: true);
    await markFromInternet(path);
    if (danger) {
      Diag.add('Получен исполняемый файл (.${fileExt(name)}) — не открыт автоматически');
      final ctx = context;
      if (ctx != null && ctx.mounted) {
        await showDialog<void>(
          context: ctx,
          builder: (d) => AlertDialog(
            icon: const Icon(Icons.gpp_maybe_rounded, color: Colors.redAccent, size: 40),
            title: const Text('Это программа или скрипт'),
            content: Text('«${p.basename(path)}» может навредить компьютеру, поэтому Ласточка его не открыла. '
                '${downloads != null ? 'Файл сохранён в «Загрузки». ' : ''}Запускайте только если точно знаете, что это, и доверяете отправителю — '
                'мошенники часто присылают вирусы от имени знакомых.'),
            actions: [
              if (downloads != null)
                TextButton(onPressed: () { Navigator.pop(d); revealInFolder(path); }, child: const Text('Показать в папке')),
              FilledButton(onPressed: () => Navigator.pop(d), child: const Text('Понятно')),
            ],
          ),
        );
      } else {
        toast('Это программа — Ласточка её не открывает. ${downloads != null ? 'Файл в «Загрузках»' : ''}');
      }
      return;
    }
    if (downloads != null) toast('Сохранено в «Загрузки»: ${p.basename(path)}');
    final r = await OpenFilex.open(path);
    if (r.type != ResultType.done) toast('Нет программы, чтобы открыть этот файл');
  } catch (e, st) {
    Diag.err('Открытие файла', e, st);
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
        } catch (e) {
          Diag.err('Загрузка фото', e);
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
    Widget frame(Widget child) => box != null
        ? SizedBox(width: box!.width, height: box!.height, child: child)
        : SizedBox(width: maxW, child: AspectRatio(aspectRatio: sticker ? 1 : ratio.clamp(0.5, 2.5), child: child));
    return GestureDetector(
      onTap: sticker
          ? null
          : big
              ? () => setState(() => _manualLoaded.add(event.eventId))
              : () {
                  // листание по всем фото и видео чата (свайп, стрелки), как в Telegram
                  final st = context.findAncestorStateOfType<_ChatPageState>();
                  openMediaViewer(context, st?._mediaList() ?? [event], event,
                      openExternally: (m) => openAttachment(m, (s) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s))), context: context));
                },
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

