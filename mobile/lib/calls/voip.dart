// Звонки 1:1 (протокол m.call.*), совместимые с настольной Ласточкой и Element.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:matrix/matrix.dart';
import 'package:webrtc_interface/webrtc_interface.dart' hide Navigator;

import '../main.dart';
import 'call_page.dart';
import 'call_stats.dart';
import 'sounds.dart';
import '../system/diag.dart';
import '../system/desktop.dart';
import '../system/lock.dart';
import '../system/notify.dart';
import '../system/trust.dart';
import 'turn_proxy.dart';

late VoIP voip;

Timer? _netDebounce;

/// Сменилась сеть во время звонка — сразу перезапускаем поиск маршрута (ICE restart), не дожидаясь,
/// пока старое соединение окончательно оборвётся: разговор продолжается после короткой паузы.
void _watchNetwork() {
  onNetworkChanged ??= () {
    _netDebounce?.cancel();
    _netDebounce = Timer(const Duration(milliseconds: 1500), () async {
      for (final c in voip.calls.values) {
        if (c.state != CallState.kConnected || c.pc == null) continue;
        Diag.mark('звонок: сменилась сеть — переподключение');
        try {
          await c.restartIce();
        } catch (e) {
          Diag.err('Переподключение звонка', e);
        }
      }
    });
  };
}

/// Исходящий звонок: данные для соединения (ICE-кандидаты) отправляются только ПОСЛЕ ответа собеседника,
/// одной порцией. До ответа они ему не нужны, а каждое событие звонка в зашифрованном чате — это отдельное
/// уведомление на iPhone с Element (сервер не видит, что внутри, и шлёт уведомление на каждое). Так на
/// пропущенный звонок приходит два события — приглашение и отбой — вместо трёх-четырёх.
/// Состояние сбора кандидатов модулю Matrix тоже передаётся только после ответа: иначе его таймеры
/// отправили бы кандидатов раньше или с лишней задержкой. После ответа всё идёт как обычно.
void _batchCandidates(CallSession s) {
  final pc = s.pc;
  final origCandidate = pc?.onIceCandidate;
  if (pc == null || origCandidate == null) return;
  final origState = pc.onIceGatheringState;
  final held = <RTCIceCandidate>[];
  RTCIceGatheringState? gathering;
  var released = false;
  StreamSubscription? sub;
  bool answered() => s.state == CallState.kConnecting || s.state == CallState.kConnected;

  void release() {
    if (released || s.callHasEnded || !answered()) return;
    released = true;
    sub?.cancel();
    pc.onIceCandidate = origCandidate;
    pc.onIceGatheringState = origState;
    Diag.mark('звонок: собеседник ответил — данные для соединения одной порцией (${held.length})');
    for (final c in held) {
      origCandidate(c);
    }
    held.clear();
    // сбор закончен — модуль отправит всё сразу; ещё идёт — дальше он работает как обычно
    final g = gathering;
    if (g != null) origState?.call(g);
  }

  pc.onIceCandidate = (c) {
    if (released) return origCandidate(c);
    held.add(c);
  };
  pc.onIceGatheringState = (st) {
    if (released) return origState?.call(st);
    gathering = st;
  };
  sub = s.onCallStateChanged.stream.listen((st) {
    if (st == CallState.kEnded) {
      sub?.cancel();
      return;
    }
    release();
  });
}

class LastochkaVoip implements WebRTCDelegate {
  @override
  MediaDevices get mediaDevices => _Media(rtc.navigator.mediaDevices);

  @override
  Future<RTCPeerConnection> createPeerConnection(Map<String, dynamic> configuration, [Map<String, dynamic> constraints = const {}]) async {
    final cfg = Map<String, dynamic>.of(configuration);
    final servers = (cfg['iceServers'] as List? ?? []).whereType<Map>().map((m) => Map<String, dynamic>.from(m)).toList();
    cfg['iceServers'] = await withTurnProxy(servers);
    return rtc.createPeerConnection(cfg, constraints);
  }

  @override
  Future<void> playRingtone() async {
    await CallSounds.incoming();
  }

  @override
  Future<void> stopRingtone() async {
    await CallSounds.stop();
  }

  @override
  Future<void> registerListeners(CallSession session) async {}

  @override
  Future<void> handleNewCall(CallSession session) async {
    CallStats.watch(session);
    _watchNetwork();
    // модуль Matrix сообщает сюда и об ИСХОДЯЩИХ звонках. Их экран уже открыл startCall — второй экран
    // звонка не открываем, «поверх блокировки» и уведомление о входящем не включаем (раньше на Android
    // открывалось два экрана звонка и окно лишний раз перестраивалось — после звонка экран застывал)
    if (session.isOutgoing) {
      _batchCandidates(session);
      callActive.value = true;
      currentCall.value = session;
      return;
    }
    ringing = session;
    callActive.value = true;
    currentCall.value = session;
    // главное окно «поверх блокировки» больше не переключаем: на заблокированном Android-телефоне звонок
    // показывает отдельное окно (CallScreen.kt), как в Telegram и WhatsApp
    navKey.currentState?.push(callRoute(session));
    // приложение свёрнуто или закрыто — полноэкранное уведомление; на компьютере — показать окно
    if (isDesktopOS) {
      await showMainWindow();
    }
    if (!appVisible) await showCallNotification(session);
    session.onCallStateChanged.stream.listen((s) {
      if (s != CallState.kRinging) {
        clearCallNotification();
        if (ringing == session) ringing = null;
      }
      if (s == CallState.kConnected) callScreenState(session.callId, 'active');
      if (s == CallState.kEnded) callScreenState(session.callId, 'ended');
    });
  }

  @override
  Future<void> handleCallEnded(CallSession session) async {
    Diag.mark('звонок: модуль сообщил о завершении');
    CallStats.ended(session);
    // «пульс» 10 секунд после звонка: если экран застынет, по следам будет видно,
    // живо ли само приложение (тогда завис системный поток) или нет
    var n = 0;
    Timer.periodic(const Duration(seconds: 1), (t) {
      Diag.mark('пульс ${++n}${n >= 10 ? ' — готово' : ''}');
      if (n >= 10) t.cancel();
    });
    // звук и флаги окна — не сразу: в эту же секунду экран звонка убирает видео и закрывается.
    // Тяжёлое для системы делаем по очереди и после того, как экран закрылся, — чтобы ничего не застывало
    unawaited(stopRingtone());
    CallSounds.hangup(); // сигнал отбоя — для любого завершения (на Android играет в своём потоке)
    callActive.value = voip.currentCID != null && voip.currentCID?.callId != session.callId;
    if (currentCall.value == session) currentCall.value = null;
    if (ringing == session) ringing = null;
    // окно на экране блокировки (если было) закрывается сразу; главное окно ничего не перестраивает
    await callScreenState(session.callId, 'ended');
    await clearCallNotification();
    Diag.mark('звонок: уведомление убрано');
  }

  @override
  Future<void> handleMissedCall(CallSession session) async {
    final ctx = navKey.currentContext;
    if (ctx == null) return;
    ScaffoldMessenger.maybeOf(ctx)?.showSnackBar(
      SnackBar(content: Text('Пропущенный звонок: ${session.room.getLocalizedDisplayname()}')),
    );
  }

  @override
  Future<void> handleNewGroupCall(GroupCallSession groupCall) async {}

  @override
  Future<void> handleGroupCallEnded(GroupCallSession groupCall) async {}

  @override
  bool get isWeb => kIsWeb;

  @override
  bool get canHandleNewCall => voip.currentCID == null && voip.currentGroupCID == null;

  @override
  EncryptionKeyProvider? get keyProvider => null;
}

/// Входящий звонок, который сейчас звонит.
CallSession? ringing;

/// Идёт звонок (входящий или исходящий).
final callActive = ValueNotifier<bool>(false);

/// Текущий звонок — для панели звонка поверх экрана блокировки.
final currentCall = ValueNotifier<CallSession?>(null);

/// Ответ на звонок — через ту же проверку смены ключа собеседника, что и отправка сообщений.
Future<void> answerCall(CallSession c) async {
  ensureCanSend(c.room);
  await c.answer();
}

void initVoip() {
  voip = VoIP(client, LastochkaVoip());
  // кнопки «Ответить» / «Отклонить» в уведомлении
  onCallAction = (action, callId) {
    // отбой из окна на экране блокировки — для идущего звонка
    if (action == 'hangup') {
      final cur = currentCall.value;
      if (cur != null && cur.callId == callId && !cur.callHasEnded) cur.hangup(reason: CallErrorCode.userHangup);
      return;
    }
    final c = ringing;
    if (c == null || c.callId != callId) return;
    if (action == 'answer_locked') {
      // ответ на заблокированном телефоне — только голосом, камера не включается
      CallSounds.stop();
      answerCall(c).then((_) async {
        if (c.type == CallType.kVideo) {
          try {
            await c.setLocalVideoMuted(true);
          } catch (_) {}
        }
      }, onError: (_) {});
      return;
    }
    if (action == 'answer') {
      CallSounds.stop();
      answerCall(c).then((_) async {
        if (c.type == CallType.kVideo && (c.localUserMediaStream?.stream?.getVideoTracks().isEmpty ?? false)) {
          try {
            await c.setLocalVideoMuted(false);
          } catch (_) {}
        }
      }, onError: (_) {});
    }
    if (action == 'decline') {
      CallSounds.stop();
      c.reject();
    }
  };
}

/// Позвонить собеседнику в чате.
Future<void> startCall(BuildContext context, Room room, {required bool video}) async {
  if (voip.currentCID != null) {
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Уже идёт другой звонок')));
    return;
  }
  try {
    ensureCanSend(room);
    final session = await voip.inviteToCall(room, video ? CallType.kVideo : CallType.kVoice);
    callActive.value = true;
    currentCall.value = session;
    if (!context.mounted) return;
    Navigator.of(context).push(callRoute(session));
  } catch (e) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(e is SendBlocked ? e.toString() : 'Не удалось позвонить: нет доступа к микрофону или камере')));
  }
}

/// Звонить можно в личный чат или в чат, где ровно два участника.
bool canCall(Room room) {
  if (room.membership != Membership.join) return false;
  if (room.isDirectChat) return true;
  final n = room.summary.mJoinedMemberCount ?? room.getParticipants([Membership.join]).length;
  return n == 2;
}

/// Камера и микрофон. Пока окно Ласточки закрыто (звонок пришёл в фоне), камеру не включаем —
/// Android её не даст, и звонок оборвался бы. Видео включится после ответа.
class _Media extends MediaDevices {
  final MediaDevices inner;
  _Media(this.inner);

  @override
  Future<MediaStream> getUserMedia(Map<String, dynamic> c) async {
    // окно скрыто или Ласточка заблокирована код-паролем — только звук (камера включится после разблокировки кнопкой)
    if ((!appVisible || AppLock.instance.locked.value) && c['video'] != null && c['video'] != false) {
      return inner.getUserMedia({...c, 'video': false});
    }
    try {
      return await inner.getUserMedia(c);
    } catch (e) {
      // камера занята или недоступна — звоним без видео
      if (c['video'] != null && c['video'] != false) return inner.getUserMedia({...c, 'video': false});
      rethrow;
    }
  }

  @override
  Future<MediaStream> getDisplayMedia(Map<String, dynamic> c) => inner.getDisplayMedia(c);

  @override
  Future<List<dynamic>> getSources() => inner.getSources();

  @override
  Future<List<MediaDeviceInfo>> enumerateDevices() => inner.enumerateDevices();

  @override
  Future<MediaDeviceInfo> selectAudioOutput([AudioOutputOptions? options]) => inner.selectAudioOutput(options);
}
