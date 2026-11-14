// Уведомления через Google (FCM) — только версия из Google Play.
// Там нет постоянной фоновой службы (правила Play): сервер Matrix отправляет «толчок» через шлюз
// уведомлений (Sygnal) в Firebase, Firebase будит Ласточку, она синхронизируется и сама показывает
// уведомление о сообщении или звонке. Во «толчке» нет текста сообщений — только номер события
// (формат event_id_only), поэтому Google переписку не видит.
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:matrix/matrix.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

/// Пришёл «толчок» от Google: сразу забрать новые сообщения и звонки.
Future<void> onPushWake() async {
  try {
    if (client.isLogged()) await client.oneShotSync().timeout(const Duration(seconds: 8));
  } catch (e) {
    Logs().w('[Ласточка] синхронизация по уведомлению Google', e);
  } finally {
    // уведомления показаны — системе можно снова «усыпить» Ласточку
    try {
      await _system.invokeMethod('pushDone');
    } catch (_) {}
  }
}
