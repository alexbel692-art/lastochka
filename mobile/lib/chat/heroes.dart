// Имена и аватарки личных чатов и чатов без названия.
//
// Модуль Matrix при запуске держит в памяти только «важные» данные чатов, без участников, а имя
// личного чата («Иван Петров») считает по участнику из памяти. Пока участник не загружен, вместо имени
// виден логин с заглавной буквы («Ivan»). Раньше это было заметно редко, а на RDP-сервере Ласточка
// перезапускается после каждого переподключения — и сразу после запуска список показывал логины.
// Поэтому после запуска (и когда появляются новые чаты) участники, по которым строится имя чата,
// загружаются из базы на устройстве; с сервера — только если в базе их нет.
import 'package:flutter/foundation.dart';
import 'package:matrix/matrix.dart';

/// Меняется, когда загрузились участники: список чатов перерисовывается с настоящими именами.
final ValueNotifier<int> heroesLoaded = ValueNotifier(0);

final Set<String> _done = {};
bool _running = false;
bool _again = false;

/// Загрузить участников, нужных для имени и аватарки чата. Повторный вызов дёшев: уже загруженные чаты пропускаются.
Future<void> loadRoomHeroes(Client client) async {
  if (_running) {
    _again = true;
    return;
  }
  _running = true;
  try {
    do {
      _again = false;
      var loaded = 0;
      for (final r in List.of(client.rooms)) {
        if (r.membership == Membership.leave || r.membership == Membership.ban) continue;
        // у чата есть своё название — участники для имени не нужны
        if (r.name.isNotEmpty && r.membership != Membership.invite) continue;
        final key = '${r.id}|${r.membership.name}|${(r.summary.mHeroes ?? const <String>[]).join(',')}|${r.directChatMatrixID}';
        if (!_done.add(key)) continue;
        try {
          await r.loadHeroUsers();
          loaded++;
        } catch (e) {
          Logs().w('[Ласточка] участники чата для названия не загрузились', e);
        }
        // перерисовываем по ходу, а не только в конце — длинный список не ждёт последнего чата
        if (loaded % 20 == 0) heroesLoaded.value++;
      }
      if (loaded > 0) heroesLoaded.value++;
    } while (_again);
  } finally {
    _running = false;
  }
}
