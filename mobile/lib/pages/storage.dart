import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../matrix_client.dart';
import '../system/lru.dart';
import '../system/privacy.dart';

String fmtSize(int b) => b < 1024 * 1024 ? '${(b / 1024).toStringAsFixed(0)} КБ' : b < 1024 * 1024 * 1024 ? '${(b / 1024 / 1024).toStringAsFixed(1)} МБ' : '${(b / 1024 / 1024 / 1024).toStringAsFixed(2)} ГБ';

/// Хранилище: сколько места занято и очистка загруженных файлов.
class StoragePage extends StatefulWidget {
  const StoragePage({super.key});
  @override
  State<StoragePage> createState() => _StoragePageState();
}

class _StoragePageState extends State<StoragePage> {
  ({int db, int files, int temp})? _u;
  int _days = 30;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final u = await storageUsage();
    final d = await fileKeepDays();
    if (!mounted) return;
    setState(() {
      _u = u;
      _days = d;
    });
  }

  Future<void> _clear() async {
    setState(() => _busy = true);
    clearMemoryCaches();
    await clearFileCache();
    await purgeDecryptedFiles();
    await _load();
    if (!mounted) return;
    setState(() => _busy = false);
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Кэш очищен — файлы скачаются заново, когда понадобятся')));
  }

  @override
  Widget build(BuildContext context) {
    final u = _u;
    final hint = Theme.of(context).hintColor;
    Widget row(IconData i, String t, String sub, int? v) => ListTile(
          leading: Icon(i, color: hint),
          title: Text(t),
          subtitle: Text(sub),
          trailing: Text(v == null ? '…' : fmtSize(v), style: const TextStyle(fontWeight: FontWeight.w600)),
        );
    return Scaffold(
      appBar: AppBar(title: const Text('Хранилище')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: ListView(children: [
            row(Icons.storage_outlined, 'Переписка и ключи', 'Зашифрованная база — не очищается', u?.db),
            row(Icons.perm_media_outlined, 'Загруженные файлы', 'Картинки, видео, голосовые, документы', u?.files),
            row(Icons.system_update_alt, 'Временные файлы', 'Скачанные обновления', u?.temp),
            Padding(
              padding: const EdgeInsets.all(16),
              child: FilledButton.icon(
                style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                onPressed: _busy || u == null ? null : _clear,
                icon: const Icon(Icons.cleaning_services_outlined),
                label: Text(u == null ? 'Очистить кэш' : 'Очистить кэш (${fmtSize(u.files + u.temp)})'),
              ),
            ),
            const Divider(),
            ListTile(
              leading: Icon(Icons.timer_outlined, color: hint),
              title: const Text('Хранить загруженные файлы'),
              subtitle: const Text('Старше этого срока удаляются с устройства сами (на сервере остаются)'),
              trailing: DropdownButton<int>(
                value: _days,
                items: const [
                  DropdownMenuItem(value: 3, child: Text('3 дня')),
                  DropdownMenuItem(value: 7, child: Text('Неделю')),
                  DropdownMenuItem(value: 30, child: Text('Месяц')),
                  DropdownMenuItem(value: 90, child: Text('3 месяца')),
                ],
                onChanged: (v) async {
                  if (v == null) return;
                  await (await SharedPreferences.getInstance()).setInt('storage.days', v);
                  setState(() => _days = v);
                  if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Применится после перезапуска Ласточки')));
                },
              ),
            ),
          ]),
        ),
      ),
    );
  }
}
