// Уведомления о сообщениях и звонках на всех платформах.
// Android: приложение держит связь с сервером через фоновую службу (как Element без Google),
// поэтому уведомления и звонки приходят, даже когда Ласточка закрыта.
// Windows/macOS: при закрытии окна Ласточка остаётся в трее/строке меню.
import 'dart:io';
import 'dart:isolate';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:matrix/matrix.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../main.dart';
import '../pages/chat.dart';
import 'desktop.dart';

final _fln = FlutterLocalNotificationsPlugin();
const _portName = 'lastochka_notification_actions';
bool _ready = false;

/// Открытый сейчас чат и видно ли окно — чтобы не уведомлять о том, что и так на экране.
String? openRoomId;
bool appVisible = true;

/// Действия с уведомлением звонка (ответить/отклонить) передаются сюда.
void Function(String action, String? payload)? onCallAction;

@pragma('vm:entry-point')
void notificationBackgroundHandler(NotificationResponse r) {
  // кнопка уведомления нажата без открытия окна — передаём в основную часть приложения
  IsolateNameServer.lookupPortByName(_portName)?.send([r.actionId ?? '', r.payload ?? '']);
}

Future<void> initNotifications() async {
  if (_ready) return;
  _ready = true;
  final port = ReceivePort();
  IsolateNameServer.removePortNameMapping(_portName);
  IsolateNameServer.registerPortWithName(port.sendPort, _portName);
  port.listen((m) {
    if (m is List && m.length == 2) _handle(m[0] as String, m[1] as String);
  });
  try {
    await _fln.initialize(
      settings: InitializationSettings(
        android: const AndroidInitializationSettings('ic_notification'),
        iOS: const DarwinInitializationSettings(requestAlertPermission: false, requestBadgePermission: false, requestSoundPermission: false),
        macOS: const DarwinInitializationSettings(),
        windows: WindowsInitializationSettings(appName: 'Ласточка', appUserModelId: 'Lastochka.App', guid: 'b4d2c8f0-5e1a-4c3b-9a7d-6f2e1d0c9b8a'),
        linux: const LinuxInitializationSettings(defaultActionName: 'Открыть'),
      ),
      onDidReceiveNotificationResponse: (r) => _handle(r.actionId ?? '', r.payload ?? ''),
      onDidReceiveBackgroundNotificationResponse: notificationBackgroundHandler,
    );
    // уведомление, по которому приложение было запущено
    final launch = await _fln.getNotificationAppLaunchDetails();
    final r = launch?.notificationResponse;
    if (launch?.didNotificationLaunchApp == true && r != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _handle(r.actionId ?? '', r.payload ?? ''));
    }
  } catch (e) {
    Logs().w('[Ласточка] уведомления недоступны', e);
  }
  client.onNotification.stream.listen(_onEvent);
}

/// Спросить разрешение на уведомления (Android 13+, iOS, macOS).
Future<void> requestNotificationPermission() async {
  try {
    if (Platform.isAndroid) {
      final a = _fln.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
      await a?.requestNotificationsPermission();
      // экран входящего звонка поверх блокировки (Android 14+): спрашиваем один раз
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool('notify.fullscreenAsked') != true) {
        await prefs.setBool('notify.fullscreenAsked', true);
        await a?.requestFullScreenIntentPermission();
      }
    } else if (Platform.isIOS) {
      await _fln.resolvePlatformSpecificImplementation<IOSFlutterLocalNotificationsPlugin>()?.requestPermissions(alert: true, badge: true, sound: true);
    } else if (Platform.isMacOS) {
      await _fln.resolvePlatformSpecificImplementation<MacOSFlutterLocalNotificationsPlugin>()?.requestPermissions(alert: true, badge: true, sound: true);
    }
  } catch (_) {}
}

void _handle(String action, String payload) {
  if (payload.startsWith('call:')) {
    onCallAction?.call(action.isEmpty ? 'open' : action, payload.substring(5));
    if (action != 'decline') showMainWindow();
    return;
  }
  if (payload.isEmpty) return;
  showMainWindow();
  final room = client.getRoomById(payload);
  if (room == null) return;
  openRoom(room);
}

/// Открыть чат из уведомления.
void openRoom(Room room) {
  final nav = navKey.currentState;
  if (nav == null) return;
  if (openRoomId == room.id) return;
  nav.popUntil((r) => r.isFirst);
  nav.push(MaterialPageRoute(builder: (_) => ChatPage(room: room)));
}

int _idFor(String roomId) => roomId.hashCode & 0x7fffffff;

Future<void> _onEvent(Event e) async {
  final room = e.room;
  if (appVisible && openRoomId == room.id) return;
  final prefs = await SharedPreferences.getInstance();
  if (prefs.getBool('notify.enabled') == false) return;
  final showText = prefs.getBool('notify.text') ?? true;
  var ev = e;
  if (ev.type == EventTypes.Encrypted && client.encryption != null) {
    try {
      ev = await client.encryption!.decryptRoomEvent(ev);
    } catch (_) {}
  }
  // звонки показываются отдельно
  if (ev.type.startsWith('m.call.')) return;
  final roomName = room.getLocalizedDisplayname();
  final sender = ev.senderFromMemoryOrFallback.calcDisplayname();
  String body;
  if (ev.type == EventTypes.RoomMember) {
    body = 'Приглашение в чат';
  } else if (!showText || ev.type == EventTypes.Encrypted) {
    body = 'Новое сообщение';
  } else {
    body = eventPreview(ev, null);
  }
  final title = room.isDirectChat ? sender : roomName;
  if (!room.isDirectChat && showText && ev.type != EventTypes.RoomMember) body = '$sender: $body';
  final unread = room.notificationCount;
  try {
    await _fln.show(
      id: _idFor(room.id),
      title: title,
      body: body,
      payload: room.id,
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          'messages',
          'Сообщения',
          channelDescription: 'Новые сообщения в чатах',
          importance: Importance.high,
          priority: Priority.high,
          category: AndroidNotificationCategory.message,
          number: unread,
          subText: unread > 1 ? '$unread новых' : null,
          groupKey: 'lastochka.messages',
          color: const Color(0xFF3390EC),
        ),
        iOS: DarwinNotificationDetails(threadIdentifier: room.id),
        macOS: DarwinNotificationDetails(threadIdentifier: room.id),
      ),
    );
  } catch (err) {
    Logs().w('[Ласточка] уведомление не показано', err);
  }
}

Future<void> clearRoomNotification(String roomId) async {
  try {
    await _fln.cancel(id: _idFor(roomId));
  } catch (_) {}
}

const _callId = 7777;

/// Входящий звонок: полноэкранное уведомление (поверх блокировки на Android) с кнопками.
Future<void> showCallNotification(CallSession call) async {
  final name = call.remoteUser?.calcDisplayname() ?? call.room.getLocalizedDisplayname();
  final video = call.type == CallType.kVideo;
  try {
    await _fln.show(
      id: _callId,
      title: name,
      body: video ? 'Входящий видеозвонок' : 'Входящий звонок',
      payload: 'call:${call.callId}',
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          'calls',
          'Звонки',
          channelDescription: 'Входящие звонки',
          importance: Importance.max,
          priority: Priority.max,
          category: AndroidNotificationCategory.call,
          fullScreenIntent: true,
          ongoing: true,
          autoCancel: false,
          playSound: false, // мелодию играет само приложение
          timeoutAfter: 60000,
          color: const Color(0xFF43A047),
          actions: const [
            AndroidNotificationAction('decline', 'Отклонить', cancelNotification: true),
            AndroidNotificationAction('answer', 'Ответить', showsUserInterface: true, cancelNotification: true),
          ],
        ),
        iOS: const DarwinNotificationDetails(interruptionLevel: InterruptionLevel.timeSensitive),
        macOS: const DarwinNotificationDetails(),
      ),
    );
  } catch (e) {
    Logs().w('[Ласточка] уведомление о звонке не показано', e);
  }
}

Future<void> clearCallNotification() async {
  try {
    await _fln.cancel(id: _callId);
  } catch (_) {}
}
