// «В сети» / «был(а) 5 минут назад» под именем в личном чате — как в Telegram.
import 'package:intl/intl.dart';

/// Текст присутствия; null — неизвестно (сервер не сообщает или человек скрыл).
String? presenceText({required bool online, required bool? currentlyActive, required DateTime? lastActive, DateTime? now}) {
  if (online || currentlyActive == true) return 'в сети';
  final t = lastActive;
  if (t == null) return null;
  final n = now ?? DateTime.now();
  final d = n.difference(t);
  if (d.isNegative || d.inSeconds < 60) return 'был(а) только что';
  if (d.inMinutes < 60) return 'был(а) ${d.inMinutes} ${_plural(d.inMinutes, 'минуту', 'минуты', 'минут')} назад';
  final day = DateTime(n.year, n.month, n.day);
  final hm = DateFormat.Hm('ru').format(t);
  if (!t.isBefore(day)) return 'был(а) сегодня в $hm';
  if (!t.isBefore(day.subtract(const Duration(days: 1)))) return 'был(а) вчера в $hm';
  if (d.inDays < 7) return 'был(а) ${DateFormat('EEEE', 'ru').format(t)} в $hm';
  return 'был(а) ${DateFormat(t.year == n.year ? 'd MMMM' : 'd MMMM y', 'ru').format(t)}';
}

String _plural(int n, String one, String few, String many) {
  final m10 = n % 10, m100 = n % 100;
  if (m10 == 1 && m100 != 11) return one;
  if (m10 >= 2 && m10 <= 4 && (m100 < 12 || m100 > 14)) return few;
  return many;
}
