import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../i18n/i18n.dart';

/// Ссылки в тексте сообщения.
class MessageLinks {
  static final _re = RegExp(r'(https?://[^\s<>]+|www\.[^\s<>]+)', caseSensitive: false);

  /// Адрес без хвостовой пунктуации («ссылка.», «(ссылка)»).
  static String _clean(String raw) {
    var u = raw;
    while (u.isNotEmpty && '.,;:!?)»”\'"'.contains(u[u.length - 1])) {
      u = u.substring(0, u.length - 1);
    }
    return u;
  }

  /// Найденные ссылки: (начало, конец, адрес).
  static List<({int start, int end, String url})> find(String text) => [
        for (final m in _re.allMatches(text))
          (start: m.start, end: m.start + _clean(m.group(0)!).length, url: _clean(m.group(0)!)),
      ];

  static Uri? uriOf(String url) => Uri.tryParse(url.toLowerCase().startsWith('http') ? url : 'https://$url');

  static String hostOf(String url) => uriOf(url)?.host.replaceFirst('www.', '') ?? url;

  static Future<void> open(String url) async {
    final u = uriOf(url);
    if (u != null) await launchUrl(u, mode: LaunchMode.externalApplication);
  }
}

/// Текст сообщения со ссылками: ссылки подчёркнуты и открываются по нажатию,
/// а под текстом — плашка с сайтом и кнопкой «Открыть».
class LinkedMessageText extends StatefulWidget {
  final String text;
  final TextStyle? style;
  const LinkedMessageText({super.key, required this.text, this.style});

  /// Есть ли в тексте хотя бы одна ссылка.
  static bool hasLink(String text) => MessageLinks.find(text).isNotEmpty;

  @override
  State<LinkedMessageText> createState() => _LinkedMessageTextState();
}

class _LinkedMessageTextState extends State<LinkedMessageText> {
  final _recognizers = <TapGestureRecognizer>[];

  void _clear() {
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();
  }

  @override
  void dispose() {
    _clear();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _clear();
    final links = MessageLinks.find(widget.text);
    final color = widget.style?.color ?? Theme.of(context).colorScheme.onSurface;
    final spans = <InlineSpan>[];
    var from = 0;
    for (final l in links) {
      if (l.start > from) spans.add(TextSpan(text: widget.text.substring(from, l.start)));
      final rec = TapGestureRecognizer()..onTap = () => MessageLinks.open(l.url);
      _recognizers.add(rec);
      spans.add(TextSpan(
        text: widget.text.substring(l.start, l.end),
        recognizer: rec,
        style: TextStyle(color: color, decoration: TextDecoration.underline, fontWeight: FontWeight.w600),
      ));
      from = l.end;
    }
    if (from < widget.text.length) spans.add(TextSpan(text: widget.text.substring(from)));
    final first = links.first.url;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      Text.rich(TextSpan(style: widget.style, children: spans)),
      const SizedBox(height: 6),
      InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () => MessageLinks.open(first),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.10),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: color.withValues(alpha: 0.25)),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.link, size: 18, color: color),
            const SizedBox(width: 8),
            Flexible(
              child: Text(MessageLinks.hostOf(first),
                  maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: color, fontWeight: FontWeight.w600)),
            ),
            const SizedBox(width: 10),
            Text(tr('Открыть'), style: TextStyle(color: color)),
            Icon(Icons.open_in_new, size: 14, color: color),
          ]),
        ),
      ),
    ]);
  }
}
