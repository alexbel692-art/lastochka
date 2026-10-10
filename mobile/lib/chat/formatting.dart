// Оформление текста, как в Telegram: **жирный**, __курсив__, ~~зачёркнутый~~, `код`, ||скрытый||,
// ссылки и упоминания. Отправляется в стандартном виде Matrix (formatted_body, HTML) —
// Element и другие клиенты показывают так же. Показ — только безопасного набора тегов.
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html;
import 'package:matrix/matrix.dart';
import 'package:url_launcher/url_launcher.dart';

String _esc(String s) => s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;').replaceAll('"', '&quot;');

final _urlRe = RegExp(r'''(?:https?://|www\.)[^\s<>"']+[^\s<>"'.,;:!?)\]}]''', caseSensitive: false);

/// Содержимое текстового сообщения. [mentions] — имя → @id упомянутых участников.
Map<String, Object?> textContent(String text, {Map<String, String> mentions = const {}}) {
  final content = <String, Object?>{'msgtype': MessageTypes.Text, 'body': text};
  final used = <String>{};
  final htmlBody = markdownToHtml(text, mentions: mentions, usedMentions: used);
  if (htmlBody != null) {
    content['format'] = 'org.matrix.custom.html';
    content['formatted_body'] = htmlBody;
  }
  content['m.mentions'] = {if (used.isNotEmpty) 'user_ids': used.toList()};
  return content;
}

/// Простая разметка → HTML. null, если оформления в тексте нет.
String? markdownToHtml(String text, {Map<String, String> mentions = const {}, Set<String>? usedMentions}) {
  final keep = <String>[];
  String hold(String s) {
    keep.add(s);
    return '\u0000${keep.length - 1}\u0000';
  }

  text = text.replaceAll('\u0000', '');
  var s = text;
  // блоки кода и код в строке — внутри них ничего не оформляем
  s = s.replaceAllMapped(RegExp(r'```(?:[a-zA-Z0-9_+-]*\n)?([\s\S]+?)```'), (m) => hold('<pre><code>${_esc(m[1]!.replaceFirst(RegExp(r'\n$'), ''))}</code></pre>'));
  s = s.replaceAllMapped(RegExp(r'`([^`\n]+)`'), (m) => hold('<code>${_esc(m[1]!)}</code>'));
  s = s.replaceAllMapped(_urlRe, (m) {
    final u = m[0]!;
    final href = u.toLowerCase().startsWith('www.') ? 'https://$u' : u;
    return hold('<a href="${_esc(href)}">${_esc(u)}</a>');
  });
  // упоминания: первое вхождение имени становится ссылкой на участника
  for (final MapEntry(key: name, value: id) in mentions.entries) {
    final i = s.indexOf(name);
    if (name.isEmpty || i < 0) continue;
    usedMentions?.add(id);
    s = s.replaceRange(i, i + name.length, hold('<a href="https://matrix.to/#/${_esc(id)}">${_esc(name)}</a>'));
  }
  s = _esc(s);
  s = s.replaceAllMapped(RegExp(r'\*\*(.+?)\*\*', dotAll: true), (m) => '<strong>${m[1]}</strong>');
  s = s.replaceAllMapped(RegExp(r'(?<![\w_])__(.+?)__(?![\w_])', dotAll: true), (m) => '<em>${m[1]}</em>');
  s = s.replaceAllMapped(RegExp(r'~~(.+?)~~', dotAll: true), (m) => '<del>${m[1]}</del>');
  s = s.replaceAllMapped(RegExp(r'\|\|(.+?)\|\|', dotAll: true), (m) => '<span data-mx-spoiler>${m[1]}</span>');
  s = s.replaceAllMapped(RegExp(r'^&gt; ?(.*)$', multiLine: true), (m) => '<blockquote>${m[1]}</blockquote>');
  s = s.replaceAll(RegExp(r'</blockquote>\n<blockquote>'), '<br>');
  s = s.replaceAll('\n', '<br>');
  s = s.replaceAllMapped(RegExp('\u0000(\\d+)\u0000'), (m) => keep[int.parse(m[1]!)]);
  final plain = _esc(text).replaceAll('\n', '<br>');
  if (s == plain) return null;
  return s;
}

/// Удалить разметку (для превью в списке чатов и уведомлениях).
String stripMarkdown(String s) => s
    .replaceAllMapped(RegExp(r'\*\*(.+?)\*\*'), (m) => m[1]!)
    .replaceAllMapped(RegExp(r'__(.+?)__'), (m) => m[1]!)
    .replaceAllMapped(RegExp(r'~~(.+?)~~'), (m) => m[1]!)
    .replaceAllMapped(RegExp(r'\|\|(.+?)\|\|'), (m) => '▒' * m[1]!.length.clamp(1, 8))
    .replaceAll('```', '')
    .replaceAllMapped(RegExp(r'`([^`]+)`'), (m) => m[1]!);

/// Открыть ссылку — только после подтверждения: видно, куда на самом деле ведёт ссылка.
Future<void> openLink(BuildContext context, String href) async {
  final uri = Uri.tryParse(href.trim());
  if (uri == null || !const ['http', 'https', 'mailto'].contains(uri.scheme.toLowerCase())) {
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Такие ссылки Ласточка не открывает')));
    return;
  }
  final ok = await showDialog<bool>(
    context: context,
    builder: (d) => AlertDialog(
      title: const Text('Открыть ссылку?'),
      content: SelectableText(uri.toString(), style: const TextStyle(fontSize: 14)),
      actions: [
        TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Отмена')),
        FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('Открыть')),
      ],
    ),
  );
  if (ok == true) {
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {}
  }
}

/// Текст сообщения с оформлением и ссылками.
class RichMessage extends StatefulWidget {
  final Event event;
  final TextStyle style;
  const RichMessage({super.key, required this.event, required this.style});
  @override
  State<RichMessage> createState() => _RichMessageState();
}

class _RichMessageState extends State<RichMessage> {
  final List<GestureRecognizer> _rec = [];
  bool _spoilers = false; // скрытый текст показан

  @override
  void dispose() {
    for (final r in _rec) {
      r.dispose();
    }
    super.dispose();
  }

  TapGestureRecognizer _tap(VoidCallback f) {
    final r = TapGestureRecognizer()..onTap = f;
    _rec.add(r);
    return r;
  }

  String? _key;
  List<InlineSpan> _spans = const [];

  @override
  Widget build(BuildContext context) {
    final e = widget.event;
    final accent = Theme.of(context).colorScheme.primary;
    final c = e.content;
    final f = c['format'] == 'org.matrix.custom.html' ? c['formatted_body'] : null;
    // разбираем заново, только когда сообщение изменилось — иначе нажатие на ссылку теряется при обновлениях
    final key = '${e.eventId}|${c['body']}|$f|$_spoilers|${accent.toARGB32()}';
    if (key == _key) return Text.rich(TextSpan(style: widget.style, children: _spans));
    _key = key;
    for (final r in _rec) {
      r.dispose();
    }
    _rec.clear();
    List<InlineSpan> spans;
    if (f is String && f.length < 60000) {
      final frag = html.parseFragment(f);
      spans = _nodes(frag.nodes, const TextStyle(), accent);
      while (spans.isNotEmpty && spans.last is TextSpan && (spans.last as TextSpan).text == '\n') {
        spans.removeLast();
      }
    } else {
      spans = _linkify(e.calcUnlocalizedBody(hideReply: true), const TextStyle(), accent);
    }
    _spans = spans;
    return Text.rich(TextSpan(style: widget.style, children: spans));
  }

  List<InlineSpan> _linkify(String text, TextStyle st, Color accent) {
    final out = <InlineSpan>[];
    var last = 0;
    for (final m in _urlRe.allMatches(text)) {
      if (m.start > last) out.add(TextSpan(text: text.substring(last, m.start), style: st));
      final u = m[0]!;
      final href = u.toLowerCase().startsWith('www.') ? 'https://$u' : u;
      out.add(TextSpan(text: u, style: st.copyWith(color: accent, decoration: TextDecoration.underline), recognizer: _tap(() => openLink(context, href))));
      last = m.end;
    }
    if (last < text.length) out.add(TextSpan(text: text.substring(last), style: st));
    return out;
  }

  List<InlineSpan> _nodes(List<dom.Node> nodes, TextStyle st, Color accent) {
    final out = <InlineSpan>[];
    for (final n in nodes) {
      if (n is dom.Text) {
        out.addAll(_linkify(n.text, st, accent));
      } else if (n is dom.Element) {
        out.addAll(_element(n, st, accent));
      }
    }
    return out;
  }

  List<InlineSpan> _element(dom.Element el, TextStyle st, Color accent) {
    List<InlineSpan> kids(TextStyle s) => _nodes(el.nodes, s, accent);
    switch (el.localName) {
      case 'mx-reply':
        return const [];
      case 'b' || 'strong':
        return kids(st.copyWith(fontWeight: FontWeight.w700));
      case 'i' || 'em':
        return kids(st.copyWith(fontStyle: FontStyle.italic));
      case 'u':
        return kids(st.copyWith(decoration: TextDecoration.underline));
      case 'del' || 's' || 'strike':
        return kids(st.copyWith(decoration: TextDecoration.lineThrough));
      case 'code':
        return kids(st.copyWith(fontFamily: 'monospace', fontFamilyFallback: const ['Menlo', 'Consolas', 'Courier New'], color: accent));
      case 'pre':
        return [const TextSpan(text: '\n'), ...kids(st.copyWith(fontFamily: 'monospace', fontFamilyFallback: const ['Menlo', 'Consolas', 'Courier New'])), const TextSpan(text: '\n')];
      case 'br':
        return const [TextSpan(text: '\n')];
      case 'p' || 'div':
        return [...kids(st), const TextSpan(text: '\n')];
      case 'h1' || 'h2' || 'h3' || 'h4' || 'h5' || 'h6':
        return [...kids(st.copyWith(fontWeight: FontWeight.w700, fontSize: (widget.style.fontSize ?? 16) * 1.15)), const TextSpan(text: '\n')];
      case 'blockquote':
        return [
          TextSpan(text: '▎', style: st.copyWith(color: accent)),
          ...kids(st.copyWith(fontStyle: FontStyle.italic)),
          const TextSpan(text: '\n'),
        ];
      case 'li':
        final ordered = el.parent?.localName == 'ol';
        final idx = ordered ? el.parent!.children.indexOf(el) + 1 : 0;
        return [TextSpan(text: ordered ? '$idx. ' : '• ', style: st), ...kids(st), const TextSpan(text: '\n')];
      case 'img':
        return [TextSpan(text: el.attributes['alt'] ?? el.attributes['title'] ?? '🖼', style: st)];
      case 'span' when el.attributes.containsKey('data-mx-spoiler'):
        if (_spoilers) return kids(st.copyWith(backgroundColor: accent.withValues(alpha: 0.12)));
        final text = el.text;
        return [
          TextSpan(
            text: '▒' * text.length.clamp(1, 40),
            style: st.copyWith(color: Colors.grey),
            recognizer: _tap(() => setState(() => _spoilers = true)),
          ),
        ];
      case 'a':
        final href = el.attributes['href'] ?? '';
        final user = RegExp(r'^https://matrix\.to/#/(@[^/?]+)').firstMatch(href)?.group(1);
        if (user != null) {
          // упоминание участника
          return [TextSpan(text: el.text.startsWith('@') ? el.text : '@${el.text}', style: st.copyWith(color: accent, fontWeight: FontWeight.w600))];
        }
        return [
          TextSpan(
            text: el.text.isEmpty ? href : el.text,
            style: st.copyWith(color: accent, decoration: TextDecoration.underline),
            recognizer: _tap(() => openLink(context, href)),
          ),
        ];
      default:
        return kids(st);
    }
  }
}
