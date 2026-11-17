// Уведомления через Google (FCM) — версия из Google Play, и через Apple (APNs) — версия из App Store.
// Android: постоянной фоновой службы нет (правила Play): сервер Matrix отправляет «толчок» через шлюз
// уведомлений (Sygnal) в Firebase, Firebase будит Ласточку, она синхронизируется и сама показывает
// уведомление о сообщении или звонке.
// iPhone: закрытую Ласточку iOS не будит, поэтому Apple показывает готовое уведомление
// «Новое сообщение» (default_payload ниже) — без имени и текста; откроете Ласточку — увидите всё.
// В обоих случаях во «толчке» нет текста сообщений — только номер события (формат event_id_only),
// поэтому ни Google, ни Apple переписку не видят.
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:matrix/matrix.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../calls/voip.dart' show ringing;
import '../main.dart' show client;

/// Сборка для Google Play (--dart-define=PLAY=true).
const bool playBuild = bool.fromEnvironment('PLAY');

/// Адрес шлюза уведомлений (секрет сборки PUSH_GATEWAY), например https://…/_matrix/push/v1/notify.
const String pushGateway = String.fromEnvironment('PUSH_GATEWAY');

/// Сборка для App Store (--dart-define=APPSTORE=true).
const bool appStoreBuild = bool.fromEnvironment('APPSTORE');

/// Должен совпадать с именем приложения в настройках шлюза (sygnal.yaml, server/setup-push-server.sh).
String get pushAppId => Platform.isIOS ? 'app.lastochka.ios' : 'app.lastochka.android';

/// Уведомление, которое Apple показывает сама (Sygnal добавляет к нему только номера комнаты и события).
const _iosPayload = {
  'aps': {
    'alert': {'title': 'Ласточка', 'body': 'Новое сообщение'},
    'sound': 'default',
  },
};

const _system = MethodChannel('lastochka/system');

bool get pushSupported => pushGateway.isNotEmpty && ((Platform.isAndroid && playBuild) || (Platform.isIOS && appStoreBuild));

/// Зарегистрировать телефон на сервере Matrix для уведомлений через Google или Apple.
/// Повторный вызов с тем же ключом ничего не меняет на сервере.
Future<void> registerPush({String? token}) async {
  if (!pushSupported || !client.isLogged()) return;
  try {
    token ??= await _system.invokeMethod<String>('pushToken');
    if (token == null || token.isEmpty) {
      Logs().w('[Ласточка] уведомления: нет ключа устройства');
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    final mark = '${client.userID}|${client.deviceID}|$token|$pushAppId';
    if (prefs.getString('push.registered') == mark) return;
    await client.postPusher(
      Pusher(
        pushkey: token,
        kind: 'http',
        appId: pushAppId,
        appDisplayName: 'Ласточка',
        deviceDisplayName: client.deviceName ?? (Platform.isIOS ? 'iPhone' : 'Android'),
        lang: 'ru',
        data: PusherData(
          url: Uri.parse(pushGateway),
          format: 'event_id_only',
          additionalProperties: Platform.isIOS ? {'default_payload': _iosPayload} : const {},
        ),
      ),
      append: true,
    );
    await prefs.setString('push.registered', mark);
    Logs().i('[Ласточка] уведомления через ${Platform.isIOS ? 'Apple' : 'Google'} включены');
  } catch (e, st) {
    Logs().w('[Ласточка] не удалось включить уведомления', e, st);
  }
}

/// Служба с микрофоном на время звонка (версия из Google Play).
Future<void> callService(bool on) async {
  if (!Platform.isAndroid || !playBuild) return;
  try {
    await _system.invokeMethod('callService', on);
  } catch (_) {}
}

/// Пришёл «толчок» от Google: сразу забрать новые сообщения и звонки.
Future<void> onPushWake() async {
  final started = DateTime.now();
  try {
    if (client.isLogged()) {
      // пока Ласточка спала, Android отключал ей сеть: незаконченный запрос синхронизации «повис»,
      // и oneShotSync ждал именно его (до таймаута). Бросаем его и сразу начинаем новый — он вернёт
      // новые события (сообщения, входящий звонок) за секунду-две
      await client.abortSync();
      client.backgroundSync = true;
      await client.oneShotSync().timeout(const Duration(seconds: 15));
    }
    // входящий звонок разбирается уже после синхронизации (расшифровка, уведомление о звонке) —
    // даём на это время, а пока звонок звонит, не отпускаем: иначе Android «заморозит» свёрнутую
    // Ласточку, и звонок покажется только когда её откроют
    await Future<void>.delayed(const Duration(milliseconds: 1500));
    while (ringing != null && DateTime.now().difference(started) < const Duration(seconds: 25)) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
  } catch (e) {
    Logs().w('[Ласточка] синхронизация по уведомлению Google', e);
  } finally {
    // уведомления показаны — системе можно снова «усыпить» Ласточку
    try {
      await _system.invokeMethod('pushDone');
    } catch (_) {}
  }
}
