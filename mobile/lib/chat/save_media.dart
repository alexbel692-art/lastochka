// «Сохранить как…»: на компьютере — окно выбора папки и имени, на телефоне — фото и видео в галерею.
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:photo_manager/photo_manager.dart';

import '../system/diag.dart';
import '../system/file_safety.dart';

bool canSaveMedia(Event e) =>
    !e.redacted &&
    (e.type == EventTypes.Sticker ||
        e.messageType == MessageTypes.Image ||
        e.messageType == MessageTypes.Video ||
        e.messageType == MessageTypes.File ||
        e.messageType == MessageTypes.Audio);

String get saveMediaLabel => Platform.isAndroid || Platform.isIOS ? 'Сохранить в галерею' : 'Сохранить как…';

String _fileName(Event e, String fallback) {
  var n = e.content.tryGet<String>('filename') ?? (e.body.contains('.') ? e.body : fallback);
  n = n.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), '_').replaceAll(RegExp(r'[\u202a-\u202e\u2066-\u2069]'), '').trim();
  n = safeFileName(n);
  if (n.isEmpty) n = fallback;
  if (!n.contains('.')) {
    final mime = e.content.tryGetMap<String, Object?>('info')?.tryGet<String>('mimetype') ?? '';
    final ext = switch (mime) {
      'image/png' => 'png',
      'image/webp' => 'webp',
      'image/gif' => 'gif',
      'video/quicktime' => 'mov',
      _ when mime.startsWith('video/') => 'mp4',
      _ when mime.startsWith('audio/') => 'ogg',
      _ => 'jpg',
    };
    n = '$n.$ext';
  }
  return n;
}

Future<void> saveMedia(BuildContext context, Event e) async {
  final m = ScaffoldMessenger.maybeOf(context);
  void toast(String s) => m?.showSnackBar(SnackBar(content: Text(s)));
  try {
    final isVideo = e.messageType == MessageTypes.Video;
    final isImage = e.messageType == MessageTypes.Image || e.type == EventTypes.Sticker;
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final name = _fileName(e, isVideo ? 'Ласточка-видео-$stamp' : 'Ласточка-$stamp');

    if (Platform.isAndroid || Platform.isIOS) {
      if (!isImage && !isVideo) {
        toast('Сохранять в галерею можно фото и видео');
        return;
      }
      final ps = await PhotoManager.requestPermissionExtend();
      if (!ps.hasAccess) {
        toast('Разрешите Ласточке доступ к фото, чтобы сохранять');
        return;
      }
      toast('Сохраняем…');
      final f = await e.downloadAndDecryptAttachment();
      if (isVideo) {
        final tmp = File(p.join((await getTemporaryDirectory()).path, 'save_$stamp${p.extension(name)}'));
        await tmp.writeAsBytes(f.bytes, flush: true);
        try {
          await PhotoManager.editor.saveVideo(tmp, title: name);
        } finally {
          try {
            await tmp.delete();
          } catch (_) {}
        }
      } else {
        await PhotoManager.editor.saveImage(f.bytes, filename: name);
      }
      m?.hideCurrentSnackBar();
      toast('Сохранено в галерею');
      return;
    }

    // компьютер: обычное окно «Сохранить как»
    // файл расшифровывается заранее — окно сохранения само запишет его в выбранное место
    final f = await e.downloadAndDecryptAttachment();
    final where = await FilePicker.saveFile(dialogTitle: 'Сохранить как', fileName: name, bytes: f.bytes);
    if (where == null) return;
    if (where.isScheme('file')) await markFromInternet(where.toFilePath());
    final saved = where.pathSegments.isEmpty ? name : where.pathSegments.last;
    toast('Сохранено: $saved');
  } catch (err, st) {
    Diag.err('Сохранение файла', err, st);
    toast('Не удалось сохранить');
  }
}
