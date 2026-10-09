import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:matrix/matrix.dart';

import '../widgets/avatar.dart';
import 'sounds.dart';

const _reasons = {
  CallErrorCode.userHangup: 'Звонок завершён',
  CallErrorCode.userBusy: 'Собеседник занят',
  CallErrorCode.inviteTimeout: 'Нет ответа',
  CallErrorCode.iceFailed: 'Не удалось соединиться',
  CallErrorCode.iceTimeout: 'Не удалось соединиться',
  CallErrorCode.userMediaFailed: 'Нет доступа к микрофону или камере',
  CallErrorCode.answeredElsewhere: 'Ответили на другом устройстве',
};

class CallPage extends StatefulWidget {
  final CallSession session;
  const CallPage({super.key, required this.session});
  @override
  State<CallPage> createState() => _CallPageState();
}

class _CallPageState extends State<CallPage> {
  CallSession get call => widget.session;
  final _remote = rtc.RTCVideoRenderer();
  final _local = rtc.RTCVideoRenderer();
  final List<StreamSubscription> _subs = [];
  Timer? _ticker;
  DateTime? _connectedAt;
  bool _speaker = false;
  bool _closing = false;
  bool _renderers = false; // видео можно подключать только после initialize()

  @override
  void initState() {
    super.initState();
    _speaker = call.type == CallType.kVideo;
    Future.wait([_remote.initialize(), _local.initialize()]).then((_) {
      _renderers = true;
      _bindStreams();
    }).catchError((Object e) => Logs().w('[Ласточка] видео недоступно', e));
    _subs.add(call.onCallStateChanged.stream.listen(_onState));
    _subs.add(call.onCallStreamsChanged.stream.listen((_) => _bindStreams()));
    _subs.add(call.onStreamAdd.stream.listen((_) => _bindStreams()));
    _subs.add(call.onStreamRemoved.stream.listen((_) => _bindStreams()));
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && _connectedAt != null) setState(() {});
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _onState(call.state));
  }

  void _bindStreams() {
    if (!mounted) return;
    if (_renderers) {
      try {
        _remote.srcObject = call.remoteUserMediaStream?.stream;
        _local.srcObject = call.localUserMediaStream?.stream;
      } catch (e) {
        Logs().w('[Ласточка] видео', e);
      }
    }
    setState(() {});
  }

  void _onState(CallState s) {
    if (!mounted) return;
    if (s == CallState.kConnected && _connectedAt == null) {
      _connectedAt = DateTime.now();
      rtc.Helper.setSpeakerphoneOn(_speaker).catchError((_) {});
    }
    if (s == CallState.kInviteSent && call.isOutgoing) CallSounds.outgoing();
    if (s == CallState.kConnecting || s == CallState.kConnected) CallSounds.stop();
    if (s == CallState.kEnded) _finish();
    setState(() {});
    _bindStreams();
  }

  /// Ответить только голосом (на видеозвонок — с выключенной камерой).
  Future<void> _answerAudio() async {
    await call.answer();
    if (call.type == CallType.kVideo) {
      try {
        await call.setLocalVideoMuted(true);
      } catch (_) {}
      _bindStreams();
    }
  }

  Future<void> _finish() async {
    if (_closing) return;
    _closing = true;
    if (_connectedAt != null || call.isOutgoing) {
      CallSounds.hangup();
    }
    setState(() {});
    await Future.delayed(const Duration(milliseconds: 1500));
    if (mounted) Navigator.of(context).maybePop();
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    _ticker?.cancel();
    if (_renderers) {
      try {
        _remote.srcObject = null;
        _local.srcObject = null;
      } catch (_) {}
    }
    _remote.dispose();
    _local.dispose();
    if (!call.callHasEnded) call.hangup(reason: CallErrorCode.userHangup).catchError((_) {});
    super.dispose();
  }

  String get _status {
    if (call.state == CallState.kEnded || _closing) return _reasons[call.hangupReason] ?? 'Звонок завершён';
    if (_connectedAt != null) {
      final d = DateTime.now().difference(_connectedAt!);
      final m = d.inMinutes.toString().padLeft(2, '0'), s = (d.inSeconds % 60).toString().padLeft(2, '0');
      return d.inHours > 0 ? '${d.inHours}:$m:$s' : '$m:$s';
    }
    return switch (call.state) {
      CallState.kRinging => call.type == CallType.kVideo ? 'Входящий видеозвонок' : 'Входящий звонок',
      CallState.kInviteSent => 'Звоним…',
      CallState.kConnecting || CallState.kCreateAnswer || CallState.kCreateOffer => 'Соединение…',
      CallState.kWaitLocalMedia => 'Включаем микрофон…',
      _ => 'Звоним…',
    };
  }

  Widget _btn(IconData icon, String label, VoidCallback? onTap, {Color? bg, Color fg = Colors.white, bool active = false}) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Material(
            color: bg ?? (active ? Colors.white : Colors.white.withValues(alpha: 0.18)),
            shape: const CircleBorder(),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: onTap,
              child: SizedBox(width: 64, height: 64, child: Icon(icon, size: 28, color: active ? Colors.black : fg)),
            ),
          ),
          const SizedBox(height: 6),
          Text(label, style: const TextStyle(color: Colors.white, fontSize: 12)),
        ],
      );

  @override
  Widget build(BuildContext context) {
    final room = call.room;
    final name = call.remoteUser?.calcDisplayname() ?? room.getLocalizedDisplayname();
    final ringing = call.state == CallState.kRinging && !call.isOutgoing && !_closing;
    final remoteVideo = _renderers && call.remoteUserMediaStream != null && !(call.remoteUserMediaStream!.isVideoMuted()) &&
        (call.remoteUserMediaStream!.stream?.getVideoTracks().isNotEmpty ?? false);
    final localVideo = _renderers && call.localUserMediaStream != null && !call.isLocalVideoMuted &&
        (call.localUserMediaStream!.stream?.getVideoTracks().isNotEmpty ?? false);
    final ended = _closing || call.callHasEnded;

    return PopScope(
      canPop: true,
      child: Scaffold(
        backgroundColor: const Color(0xFF1C2733),
        body: Stack(children: [
          if (remoteVideo)
            Positioned.fill(child: rtc.RTCVideoView(_remote, objectFit: rtc.RTCVideoViewObjectFit.RTCVideoViewObjectFitCover))
          else
            Positioned.fill(
              child: DecoratedBox(
                decoration: const BoxDecoration(
                  gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color(0xFF3A6EA5), Color(0xFF1C2733)]),
                ),
              ),
            ),
          SafeArea(
            child: Column(children: [
              SizedBox(height: MediaQuery.sizeOf(context).height < 500 ? 12 : 40),
              if (!remoteVideo) Avatar(mxc: call.remoteUser?.avatarUrl ?? room.avatar, name: name, size: min(120.0, MediaQuery.sizeOf(context).height * 0.18)),
              const SizedBox(height: 18),
              Text(name, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white, fontSize: 26, fontWeight: FontWeight.w600)),
              const SizedBox(height: 6),
              Text(_status, style: TextStyle(color: Colors.white.withValues(alpha: 0.8), fontSize: 16)),
              const Spacer(),
              if (ringing)
                Padding(
                  padding: const EdgeInsets.only(bottom: 40),
                  child: Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
                    _btn(Icons.call_end, 'Отклонить', () => call.reject(), bg: const Color(0xFFE53935)),
                    _btn(Icons.call, call.type == CallType.kVideo ? 'Без видео' : 'Ответить', _answerAudio, bg: const Color(0xFF43A047)),
                    if (call.type == CallType.kVideo)
                      _btn(Icons.videocam, 'С видео', () => call.answer(), bg: const Color(0xFF43A047)),
                  ]),
                )
              else if (!ended)
                Padding(
                  padding: const EdgeInsets.only(bottom: 40, left: 12, right: 12),
                  child: Column(children: [
                    Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
                      _btn(_speaker ? Icons.volume_up : Icons.volume_down, 'Динамик', () {
                        setState(() => _speaker = !_speaker);
                        rtc.Helper.setSpeakerphoneOn(_speaker).catchError((_) {});
                      }, active: _speaker),
                      _btn(call.isLocalVideoMuted || !localVideo ? Icons.videocam_off : Icons.videocam, 'Видео', () async {
                        await call.setLocalVideoMuted(localVideo);
                        _bindStreams();
                      }, active: localVideo),
                      _btn(call.isMicrophoneMuted ? Icons.mic_off : Icons.mic, call.isMicrophoneMuted ? 'Микр. выкл.' : 'Микрофон', () async {
                        await call.setMicrophoneMuted(!call.isMicrophoneMuted);
                        setState(() {});
                      }, active: call.isMicrophoneMuted),
                    ]),
                    const SizedBox(height: 22),
                    _btn(Icons.call_end, 'Завершить', () => call.hangup(reason: CallErrorCode.userHangup), bg: const Color(0xFFE53935)),
                  ]),
                )
              else
                const SizedBox(height: 120),
            ]),
          ),
          if (localVideo && !ended)
            Positioned(
              right: 16,
              top: MediaQuery.paddingOf(context).top + 16,
              width: 110,
              height: 160,
              child: GestureDetector(
                onTap: () {
                  final t = call.localUserMediaStream?.stream?.getVideoTracks().firstOrNull;
                  if (t != null) rtc.Helper.switchCamera(t).catchError((_) => false);
                },
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(14),
                  child: rtc.RTCVideoView(_local, mirror: true, objectFit: rtc.RTCVideoViewObjectFit.RTCVideoViewObjectFitCover),
                ),
              ),
            ),
        ]),
      ),
    );
  }
}
