import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:matrix/matrix.dart';

import '../chat/names.dart' show cleanName;
import '../widgets/avatar.dart';
import '../system/diag.dart';
import 'sounds.dart';
import '../system/notify.dart' show keyguardLocked;
import '../system/trust.dart' show SendBlocked;
import 'voip.dart' show answerCall;

const _reasons = {
  CallErrorCode.userHangup: 'Звонок завершён',
  CallErrorCode.userBusy: 'Собеседник занят',
  CallErrorCode.inviteTimeout: 'Нет ответа',
  CallErrorCode.iceFailed: 'Не удалось соединиться',
  CallErrorCode.iceTimeout: 'Не удалось соединиться',
  CallErrorCode.userMediaFailed: 'Нет доступа к микрофону или камере',
  CallErrorCode.answeredElsewhere: 'Ответили на другом устройстве',
};

/// Экран звонка открывается коротким проявлением, а закрывается мгновенно, без анимации — как в Telegram
/// и WhatsApp. В момент отбоя Android занят освобождением камеры, микрофона и звука; анимация
/// «уменьшения» обрывалась на полпути, и экран застывал наполовину тёмным.
Route<void> callRoute(CallSession session) => PageRouteBuilder<void>(
      opaque: true,
      transitionDuration: const Duration(milliseconds: 150),
      reverseTransitionDuration: Duration.zero,
      pageBuilder: (_, __, ___) => CallPage(session: session),
      transitionsBuilder: (_, a, __, child) => FadeTransition(opacity: a, child: child),
    );

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
  bool _keyguard = false; // телефон заблокирован: «Назад» не открывает чаты поверх экрана блокировки
  String? _unreachable; // исходящий: сеансы собеседника, которым ключи не уходят (звонок там не зазвонит)
  final _started = Stopwatch()..start();

  @override
  void initState() {
    super.initState();
    _speaker = call.type == CallType.kVideo;
    Diag.mark('звонок: экран открыт (${call.type == CallType.kVideo ? 'видео' : 'аудио'}, ${call.isOutgoing ? 'исходящий' : 'входящий'})', start: true);
    // окна видео создаются, только когда видео действительно есть: сразу для видеозвонка,
    // а на голосовом — как только кто-то включит камеру (в том числе собеседник из Element).
    // Лишние окна на аудиозвонке не нужны: их освобождение на старых Android подвешивало приложение
    if (call.type == CallType.kVideo) _ensureRenderers();
    if (call.isOutgoing) _unreachable = _unreachableNote();
    _subs.add(call.onCallStateChanged.stream.listen(_onState));
    _subs.add(call.onCallStreamsChanged.stream.listen((_) => _bindStreams()));
    _subs.add(call.onStreamAdd.stream.listen((_) => _bindStreams()));
    _subs.add(call.onStreamRemoved.stream.listen((_) => _bindStreams()));
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) async {
      final k = await keyguardLocked();
      if (mounted && (k != _keyguard || (_connectedAt != null && !_closing))) setState(() => _keyguard = k);
    });
    keyguardLocked().then((k) => mounted ? setState(() => _keyguard = k) : null);
    WidgetsBinding.instance.addPostFrameCallback((_) => _onState(call.state));
  }

  Future<void>? _rendInit;

  Future<void> _ensureRenderers() => _rendInit ??= Future.wait([_remote.initialize(), _local.initialize()]).then((_) {
        if (!mounted || _closing) return;
        _renderers = true;
        Diag.mark('звонок: окна видео готовы');
        _bindStreams();
      }).catchError((Object e) {
        Diag.err('Окна видео', e);
      });

  bool get _anyVideo =>
      (call.remoteUserMediaStream?.stream?.getVideoTracks().isNotEmpty ?? false) || (call.localUserMediaStream?.stream?.getVideoTracks().isNotEmpty ?? false);

  bool _sawRemoteVideo = false;

  void _bindStreams() {
    if (!mounted || _closing) return;
    if (!_renderers && !_closing && _anyVideo) _ensureRenderers();
    final rv = call.remoteUserMediaStream?.stream?.getVideoTracks().isNotEmpty ?? false;
    if (rv && !_sawRemoteVideo) {
      _sawRemoteVideo = true;
      Diag.mark('звонок: пришло видео собеседника');
    }
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

  /// Ласточка отдаёт ключи шифрования только сеансам, которые собеседник сам подтвердил (кросс-подпись).
  /// Неподтверждённый сеанс (например, Element, где пропустили подтверждение входа) получит приглашение
  /// в звонок, но не сможет его расшифровать — и не зазвонит. Говорим об этом сразу, а не молча.
  String? _unreachableNote() {
    final uid = call.remoteUser?.id ?? call.room.directChatMatrixID;
    if (uid == null) return null;
    final devices = call.room.client.userDeviceKeys[uid]?.deviceKeys.values.where((d) => !d.blocked).toList() ?? const [];
    final skipped = devices.where((d) => !d.encryptToDevice).toList();
    if (skipped.isEmpty) return null;
    String label(DeviceKeys d) {
      final n = cleanName(d.deviceDisplayName ?? '');
      return n.isEmpty ? (d.deviceId ?? '?') : (n.length > 30 ? '${n.substring(0, 30)}…' : n);
    }

    final names = skipped.map(label).take(3).join(', ');
    Diag.add('Звонок: ${skipped.length} из ${devices.length} сеансов собеседника не подтверждены — ключи им не отправлены');
    return skipped.length == devices.length
        ? 'Звонок не дойдёт: ни один сеанс собеседника не подтверждён ($names). Пусть он подтвердит вход в Element или Ласточке.'
        : 'На неподтверждённых сеансах собеседника ($names) звонок не зазвонит. Пусть он подтвердит их со своего основного устройства.';
  }

  void _onState(CallState s) {
    if (!mounted) return;
    // ход звонка с отметкой времени — в отчёте видно, на каком шаге он остановился
    Diag.mark('звонок: ${s.name} (${_started.elapsedMilliseconds} мс)');
    if (s == CallState.kConnected && _connectedAt == null) {
      _connectedAt = DateTime.now();
      if (Platform.isAndroid || Platform.isIOS) rtc.Helper.setSpeakerphoneOn(_speaker).catchError((_) {});
    }
    if (s == CallState.kInviteSent && call.isOutgoing) CallSounds.outgoing();
    if (s == CallState.kConnecting || s == CallState.kConnected) CallSounds.stop();
    if (s == CallState.kEnded) {
      // сначала убираем с экрана окна видео (одним лёгким кадром), потом закрываем экран;
      // всё системное (звук, флаги окна, уведомление) модуль звонков делает позже и не на этом кадре
      Diag.mark('звонок: завершён (${call.hangupReason})');
      _ticker?.cancel();
      _detach();
      _finish();
      return;
    }
    setState(() {});
    _bindStreams();
  }

  Future<bool> _answer() async {
    try {
      await answerCall(call);
      return true;
    } on SendBlocked catch (e) {
      if (mounted) ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(e.toString())));
      return false;
    }
  }

  /// Ответить только голосом (на видеозвонок — с выключенной камерой).
  /// Ответ с видео: если звонок пришёл в фоне, камера ещё не включена — включаем после ответа.
  Future<void> _answerVideo() async {
    Diag.mark('звонок: ответ с видео');
    CallSounds.stop();
    if (!await _answer()) return;
    if (call.localUserMediaStream?.stream?.getVideoTracks().isEmpty ?? false) {
      try {
        await call.setLocalVideoMuted(false);
      } catch (_) {}
    }
    _bindStreams();
  }

  Future<void> _answerAudio() async {
    Diag.mark('звонок: ответ');
    CallSounds.stop();
    if (!await _answer()) return;
    if (call.type == CallType.kVideo) {
      try {
        await call.setLocalVideoMuted(true);
      } catch (_) {}
      _bindStreams();
    }
  }

  /// Отвязать видео от потоков сразу, пока модуль звонков их освобождает.
  void _detach() {
    if (!_renderers) return;
    _renderers = false;
    try {
      _remote.srcObject = null;
      _local.srcObject = null;
    } catch (_) {}
  }

  Future<void> _finish() async {
    if (_closing) return;
    _closing = true;
    if (mounted) setState(() {});
    // короткая пауза, чтобы было видно «Звонок завершён» (как в Telegram и WhatsApp — меньше полсекунды)
    await Future.delayed(const Duration(milliseconds: 300));
    if (!mounted) return;
    Diag.mark('звонок: закрываем экран');
    final route = ModalRoute.of(context);
    final nav = Navigator.of(context);
    // закрываем именно экран звонка, даже если поверх него что-то открыто (раньше закрывалось верхнее окно,
    // а экран звонка оставался висеть)
    if (route == null) return;
    if (route.isCurrent) {
      nav.pop();
    } else if (route.isActive) {
      nav.removeRoute(route);
    }
    // экран под звонком перерисовываем сразу и ещё раз чуть позже: если система в эту секунду
    // перестраивала окно (звук, камера), первый кадр мог не дойти до экрана
    WidgetsBinding.instance.scheduleForcedFrame();
    Future.delayed(const Duration(milliseconds: 300), () => WidgetsBinding.instance.scheduleForcedFrame());
    Future.delayed(const Duration(milliseconds: 1000), () => WidgetsBinding.instance.scheduleForcedFrame());
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    _ticker?.cancel();
    final init = _rendInit;
    _detach();
    if (!call.callHasEnded) call.hangup(reason: CallErrorCode.userHangup).catchError((_) {});
    // окна видео освобождаем чуть позже — когда модуль звонков закончит со своими потоками
    if (init != null) {
      final r = _remote, l = _local;
      init.whenComplete(() => Future.delayed(const Duration(seconds: 2), () {
            r.dispose().catchError((_) {});
            l.dispose().catchError((_) {});
          }));
    }
    Diag.mark('звонок: экран закрыт — готово');
    super.dispose();
  }

  String get _status {
    if (call.state == CallState.kEnded || _closing) return _reasons[call.hangupReason] ?? 'Звонок завершён';
    if (_connectedAt != null) {
      final ice = call.pc?.iceConnectionState;
      if (ice == rtc.RTCIceConnectionState.RTCIceConnectionStateDisconnected || ice == rtc.RTCIceConnectionState.RTCIceConnectionStateChecking) {
        return 'Переподключение…';
      }
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
      canPop: !_keyguard,
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
              if (_unreachable != null && _connectedAt == null && !ended)
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 14, 24, 0),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    decoration: BoxDecoration(color: const Color(0xCCB26A00), borderRadius: BorderRadius.circular(12)),
                    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      const Icon(Icons.gpp_maybe_rounded, color: Colors.white, size: 20),
                      const SizedBox(width: 8),
                      Expanded(child: Text(_unreachable!, style: const TextStyle(color: Colors.white, fontSize: 13.5, height: 1.3))),
                    ]),
                  ),
                ),
              const Spacer(),
              if (ringing)
                Padding(
                  padding: const EdgeInsets.only(bottom: 40),
                  child: Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
                    _btn(Icons.call_end, 'Отклонить', () => call.reject(), bg: const Color(0xFFE53935)),
                    _btn(Icons.call, call.type == CallType.kVideo ? 'Без видео' : 'Ответить', _answerAudio, bg: const Color(0xFF43A047)),
                    if (call.type == CallType.kVideo)
                      _btn(Icons.videocam, 'С видео', _answerVideo, bg: const Color(0xFF43A047)),
                  ]),
                )
              else if (!ended)
                Padding(
                  padding: const EdgeInsets.only(bottom: 40, left: 12, right: 12),
                  child: Column(children: [
                    Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
                      // громкая связь есть только на телефоне
                      if (Platform.isAndroid || Platform.isIOS)
                        _btn(_speaker ? Icons.volume_up : Icons.volume_down, 'Динамик', () {
                          setState(() => _speaker = !_speaker);
                          rtc.Helper.setSpeakerphoneOn(_speaker).catchError((_) {});
                        }, active: _speaker),
                      _btn(call.isLocalVideoMuted || !localVideo ? Icons.videocam_off : Icons.videocam, 'Видео', () async {
                        final on = !localVideo;
                        try {
                          await call.setLocalVideoMuted(!on);
                        } catch (e) {
                          Diag.err('Включение камеры', e);
                        }
                        if (on) {
                          if (!(call.localUserMediaStream?.stream?.getVideoTracks().isNotEmpty ?? false)) {
                            // модуль звонков не смог добавить видео (например, собеседник не прислал описание потоков)
                            Diag.add('Камера не включилась: видео в этот звонок не добавлено');
                            if (context.mounted) {
                              ScaffoldMessenger.maybeOf(context)?.showSnackBar(const SnackBar(content: Text('Не удалось включить камеру в этом звонке')));
                            }
                          } else {
                            Diag.mark('звонок: камера включена');
                            await _ensureRenderers();
                            // с видео удобнее говорить по громкой связи, как в Telegram
                            if (!_speaker) {
                              setState(() => _speaker = true);
                              if (Platform.isAndroid || Platform.isIOS) rtc.Helper.setSpeakerphoneOn(true).catchError((_) {});
                            }
                          }
                        }
                        _bindStreams();
                      }, active: localVideo),
                      _btn(call.isMicrophoneMuted ? Icons.mic_off : Icons.mic, call.isMicrophoneMuted ? 'Микр. выкл.' : 'Микрофон', () async {
                        await call.setMicrophoneMuted(!call.isMicrophoneMuted);
                        setState(() {});
                      }, active: call.isMicrophoneMuted),
                    ]),
                    const SizedBox(height: 22),
                    _btn(Icons.call_end, 'Завершить', () {
                      Diag.mark('звонок: нажато «Завершить»');
                      call.hangup(reason: CallErrorCode.userHangup);
                    }, bg: const Color(0xFFE53935)),
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
