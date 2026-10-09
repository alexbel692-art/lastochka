// Звонки 1:1 (протокол m.call.*), совместимые с настольной Ласточкой и Element.
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_ringtone_player/flutter_ringtone_player.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:matrix/matrix.dart';
import 'package:webrtc_interface/webrtc_interface.dart' hide Navigator;

import '../main.dart';
import 'call_page.dart';
import 'turn_proxy.dart';

late VoIP voip;

class LastochkaVoip implements WebRTCDelegate {
  final _ring = FlutterRingtonePlayer();

  @override
  MediaDevices get mediaDevices => rtc.navigator.mediaDevices;

  @override
  Future<RTCPeerConnection> createPeerConnection(Map<String, dynamic> configuration, [Map<String, dynamic> constraints = const {}]) async {
    final cfg = Map<String, dynamic>.of(configuration);
    final servers = (cfg['iceServers'] as List? ?? []).whereType<Map>().map((m) => Map<String, dynamic>.from(m)).toList();
    cfg['iceServers'] = await withTurnProxy(servers);
    return rtc.createPeerConnection(cfg, constraints);
  }

  @override
  Future<void> playRingtone() async {
    try {
      await _ring.playRingtone(looping: true);
    } catch (_) {}
  }

  @override
  Future<void> stopRingtone() async {
    try {
      await _ring.stop();
    } catch (_) {}
  }

  @override
  Future<void> registerListeners(CallSession session) async {}

  @override
  Future<void> handleNewCall(CallSession session) async {
    navKey.currentState?.push(MaterialPageRoute(builder: (_) => CallPage(session: session)));
  }

  @override
  Future<void> handleCallEnded(CallSession session) async {
    await stopRingtone();
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

void initVoip() {
  voip = VoIP(client, LastochkaVoip());
}

/// Позвонить собеседнику в чате.
Future<void> startCall(BuildContext context, Room room, {required bool video}) async {
  if (voip.currentCID != null) {
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Уже идёт другой звонок')));
    return;
  }
  try {
    final session = await voip.inviteToCall(room, video ? CallType.kVideo : CallType.kVoice);
    if (!context.mounted) return;
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => CallPage(session: session)));
  } catch (e) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Не удалось позвонить: нет доступа к микрофону или камере')));
  }
}
