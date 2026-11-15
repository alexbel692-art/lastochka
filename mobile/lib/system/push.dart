// Уведомления через Google (FCM) — только версия из Google Play.
// Там нет постоянной фоновой службы (правила Play): сервер Matrix отправляет «толчок» через шлюз
// уведомлений (Sygnal) в Firebase, Firebase будит Ласточку, она синхронизируется и сама показывает
// уведомление о сообщении или звонке. Во «толчке» нет текста сообщений — только номер события
// (формат event_id_only), поэтому Google переписку не видит.
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

/// Должен совпадать с именем приложения в настройках шлюза (sygnal.yaml).
const String pushAppId = 'app.lastochka.android';

const _system = MethodChannel('lastochka/system');

bool get pushSupported => Platform.isAndroid && playBuild && pushGateway.isNotEmpty;

/// Зарегистрировать телефон на сервере Matrix для уведомлений через Google.
/// Повторный вызов с тем же ключом ничего не меняет на сервере.
Future<void> registerPush({String? token}) async {
  if (!pushSupported || !client.isLogged()) return;
  try {
    token ??= await _system.invokeMethod<String>('pushToken');
    if (token == null || token.isEmpty) {
      Logs().w('[Ласточка] уведомления Google: нет ключа устройства');
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    final mark = '${client.userID}|${client.deviceID}|$token';
    if (prefs.getString('push.registered') == mark) return;
    await client.postPusher(
      Pusher(
        pushkey: token,
        kind: 'http',
        appId: pushAppId,
        appDisplayName: 'Ласточка',
        deviceDisplayName: client.deviceName ?? 'Android',
        lang: 'ru',
        data: PusherData(url: Uri.parse(pushGateway), format: 'event_id_only'),
      ),
      append: true,
    );
    await prefs.setString('push.registered', mark);
    Logs().i('[Ласточка] уведомления Google включены');
  } catch (e, st) {
    Logs().w('[Ласточка] не удалось включить уведомления Google', e, st);
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
