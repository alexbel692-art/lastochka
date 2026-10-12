// Панель звонка поверх экрана блокировки Ласточки: ответить, отклонить, выключить микрофон, завершить —
// не открывая сами чаты. Раньше звонок снимал код-пароль со всего приложения.
import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart';

import '../widgets/avatar.dart';
import 'sounds.dart';

class LockedCallPanel extends StatelessWidget {
  final CallSession session;
  const LockedCallPanel({super.key, required this.session});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<CallState>(
      stream: session.onCallStateChanged.stream,
      initialData: session.state,
      builder: (context, s) {
        final st = s.data ?? session.state;
        if (st == CallState.kEnded) return const SizedBox.shrink();
        final ringing = st == CallState.kRinging && !session.isOutgoing;
        final name = session.remoteUser?.calcDisplayname() ?? session.room.getLocalizedDisplayname();
        final status = ringing
            ? (session.type == CallType.kVideo ? 'Входящий видеозвонок' : 'Входящий звонок')
            : st == CallState.kConnected
                ? 'Идёт звонок — введите код, чтобы открыть Ласточку'
                : 'Соединение…';
        return SafeArea(
          bottom: false,
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Material(
            color: const Color(0xFF1C2733),
            elevation: 6,
            borderRadius: BorderRadius.circular(18),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
              child: Row(children: [
                Avatar(mxc: session.remoteUser?.avatarUrl ?? session.room.avatar, name: name, size: 44),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                    Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600)),
                    Text(status, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white70, fontSize: 12.5)),
                  ]),
                ),
                if (ringing) ...[
                  _round(Icons.call_end, const Color(0xFFE53935), 'Отклонить', () {
                    CallSounds.stop();
                    session.reject();
                  }),
                  const SizedBox(width: 8),
                  // ответ с экрана блокировки — только голосом, камера не включается
                  _round(Icons.call, const Color(0xFF43A047), 'Ответить', () async {
                    CallSounds.stop();
                    await session.answer();
                    if (session.type == CallType.kVideo) {
                      try {
                        await session.setLocalVideoMuted(true);
                      } catch (_) {}
                    }
                  }),
                ] else ...[
                  StatefulBuilder(
                    builder: (context, set) => _round(
                      session.isMicrophoneMuted ? Icons.mic_off : Icons.mic,
                      Colors.white24,
                      session.isMicrophoneMuted ? 'Включить микрофон' : 'Выключить микрофон',
                      () async {
                        await session.setMicrophoneMuted(!session.isMicrophoneMuted);
                        set(() {});
                      },
                    ),
                  ),
                  const SizedBox(width: 8),
                  _round(Icons.call_end, const Color(0xFFE53935), 'Завершить', () => session.hangup(reason: CallErrorCode.userHangup)),
                ],
              ]),
            ),
          ),
          ),
        );
      },
    );
  }

  Widget _round(IconData icon, Color bg, String tip, VoidCallback onTap) => Tooltip(
        message: tip,
        child: Material(
          color: bg,
          shape: const CircleBorder(),
          child: InkWell(customBorder: const CircleBorder(), onTap: onTap, child: SizedBox(width: 48, height: 48, child: Icon(icon, color: Colors.white))),
        ),
      );
}
