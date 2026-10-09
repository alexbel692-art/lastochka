// Звонки 1:1 (протокол m.call.*), совместимые с настольной Ласточкой и Element.
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:matrix/matrix.dart';
import 'package:webrtc_interface/webrtc_interface.dart' hide Navigator;

import '../main.dart';
import 'call_page.dart';
import 'sounds.dart';
import '../system/desktop.dart';
import '../system/notify.dart';
import 'turn_proxy.dart';

late VoIP voip;

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
    ringing = session;
    callActive.value = true;
    await setCallMode(true);
    navKey.currentState?.push(MaterialPageRoute(builder: (_) => CallPage(session: session)));
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
    });
  }

  @override
  Future<void> handleCallEnded(CallSession session) async {
    await stopRingtone();
    // звук окончания — для любого завершения: сбросили вы, собеседник, отклонили или не дозвонились
    CallSounds.hangup();
    callActive.value = voip.currentCID != null && voip.currentCID?.callId != session.callId;
    await clearCallNotification();
    await setCallMode(false);
    if (ringing == session) ringing = null;
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

/// Идёт звонок (входящий или исходящий) — экран блокировки его не закрывает.
final callActive = ValueNotifier<bool>(false);

void initVoip() {
  voip = VoIP(client, LastochkaVoip());
  // кнопки «Ответить» / «Отклонить» в уведомлении
  onCallAction = (action, callId) {
    final c = ringing;
    if (c == null || c.callId != callId) return;
    if (action == 'answer') {
      c.answer().then((_) async {
        if (c.type == CallType.kVideo && (c.localUserMediaStream?.stream?.getVideoTracks().isEmpty ?? false)) {
          try {
            await c.setLocalVideoMuted(false);
          } catch (_) {}
        }
      });
    }
    if (action == 'decline') c.reject();
  };
}

/// Позвонить собеседнику в чате.
Future<void> startCall(BuildContext context, Room room, {required bool video}) async {
  if (voip.currentCID != null) {
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Уже идёт другой звонок')));
    return;
  }
  try {
    final session = await voip.inviteToCall(room, video ? CallType.kVideo : CallType.kVoice);
    callActive.value = true;
    if (!context.mounted) return;
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => CallPage(session: session)));
  } catch (e) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Не удалось позвонить: нет доступа к микрофону или камере')));
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
    if (!appVisible && c['video'] != null && c['video'] != false) {
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
