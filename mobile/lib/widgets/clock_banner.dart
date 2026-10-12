// Полоска «Часы на этом устройстве неправильные» — иначе подтверждение входа с другого
// устройства отменяется (Matrix сверяет время), а сообщения могут вставать не по порядку.
import 'dart:async';

import 'package:flutter/material.dart';

import '../system/clock.dart';

class ClockBanner extends StatefulWidget {
  const ClockBanner({super.key});
  @override
  State<ClockBanner> createState() => _ClockBannerState();
}

class _ClockBannerState extends State<ClockBanner> {
  Duration? _skew;
  Timer? _t;
  bool _hidden = false;

  @override
  void initState() {
    super.initState();
    _check();
    _t = Timer.periodic(const Duration(minutes: 30), (_) => _check());
  }

  Future<void> _check() async {
    final d = await clockSkew(fresh: true);
    if (mounted) setState(() => _skew = d);
  }

  @override
  void dispose() {
    _t?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_hidden || !skewMatters(_skew)) return const SizedBox.shrink();
    return Material(
      color: Colors.orange.withValues(alpha: 0.15),
      child: InkWell(
        onTap: () => showDialog<void>(
          context: context,
          builder: (d) => AlertDialog(
            title: const Text('Неправильное время'),
            content: Text('Часы этого устройства ${skewText(_skew!)} относительно сервера. Из-за этого не проходит подтверждение входа с другого устройства. '
                '$fixClockHint\n\nЧасовой пояс может быть любым — важно, чтобы время ставилось автоматически.'),
            actions: [
              TextButton(onPressed: () { Navigator.pop(d); setState(() => _hidden = true); }, child: const Text('Скрыть')),
              FilledButton(onPressed: () { Navigator.pop(d); _check(); }, child: const Text('Проверить снова')),
            ],
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 12, 10),
          child: Row(children: [
            Icon(Icons.schedule_rounded, color: Colors.orange.shade800, size: 20),
            const SizedBox(width: 10),
            Expanded(child: Text('Часы на этом устройстве ${skewText(_skew!)} — нажмите, чтобы исправить', style: TextStyle(color: Colors.orange.shade900, fontSize: 13.5))),
          ]),
        ),
      ),
    );
  }
}
