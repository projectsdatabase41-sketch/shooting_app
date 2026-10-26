import '../services/knowledge_service.dart';
import 'text_search.dart';

/// Одна дословная цитата из книги или методички.
class SourceQuote {
  final String source;
  final String heading;
  final String text;
  const SourceQuote(this.source, this.heading, this.text);
}

/// Универсальный отбор цитат для ответа: без обращения к модели, по одному и тому же правилу для любого вопроса.
///
/// Идея: содержание книг пользователь читает в виде дословных отрывков с указанием, откуда они, а не в пересказе
/// модели (пересказ — это «как я понял прочитанное», в нём путаются термины и появляется выдумка). Модель остаётся
/// для данных пользователя и связки, а алгоритм находит и показывает первоисточник.
///
/// Правило отбора: куски оцениваются `TextSearch.weightedRelevance` (слово в заголовке раздела весит больше), берутся
/// те, у кого оценка не ниже [minShare] от лучшей (и не ниже [minScore]); из каждого куска вырезается ближайшее к
/// словам вопроса окно целых предложений — текст не изменяется ни на букву.
class SourceQuotes {
  SourceQuotes._();

  static List<SourceQuote> pick(
    List<KnowledgeChunk> chunks,
    List<String> words, {
    Set<String> excludeTables = const {},
    int maxQuotes = 4,
    double minShare = 0.5,
    int minScore = 3,
    int maxChars = 700,
  }) {
    if (words.isEmpty) return const [];
    final scored = <(KnowledgeChunk, int)>[
      for (final c in chunks)
        if (!excludeTables.contains(c.table)) (c, TextSearch.weightedRelevance(c.heading, c.text, words)),
    ]..sort((a, b) => b.$2.compareTo(a.$2));
    if (scored.isEmpty || scored.first.$2 < minScore) return const [];
    final bar = (scored.first.$2 * minShare).ceil();
    final out = <SourceQuote>[];
    final seen = <String>{};
    for (final (c, s) in scored) {
      if (s < bar || s < minScore) break;
      final text = window(c.text, words, maxChars);
      if (text.isEmpty || !seen.add(text)) continue;
      out.add(SourceQuote(c.source, c.heading, text));
      if (out.length >= maxQuotes) break;
    }
    return out;
  }

  /// Окно целых предложений до [maxChars] знаков вокруг самого «насыщенного» словами вопроса места. Текст берётся как есть.
  static String window(String raw, List<String> words, int maxChars) {
    final text = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (text.length <= maxChars) return text;
    final sentences = RegExp(r'[^.!?…]+[.!?…]+(?:\s|$)|[^.!?…]+$').allMatches(text).map((m) => m.group(0)!.trim()).where((s) => s.isNotEmpty).toList();
    if (sentences.isEmpty) return '${text.substring(0, maxChars)}…';
    int score(String s) => TextSearch.relevance(s, words);
    var best = 0, bestScore = -1;
    for (var i = 0; i < sentences.length; i++) {
      final sc = score(sentences[i]);
      if (sc > bestScore) {
        bestScore = sc;
        best = i;
      }
    }
    var from = best, to = best; // включительно
    var len = sentences[best].length;
    // Окно растёт по предложению вперёд и назад, пока помещается в [maxChars]; заканчивается, когда расти некуда.
    var grew = true;
    while (grew) {
      grew = false;
      if (to + 1 < sentences.length && len + 1 + sentences[to + 1].length <= maxChars) {
        to++;
        len += 1 + sentences[to].length;
        grew = true;
      }
      if (from > 0 && len + 1 + sentences[from - 1].length <= maxChars) {
        from--;
        len += 1 + sentences[from].length;
        grew = true;
      }
    }
    final body = sentences.sublist(from, to + 1).join(' ');
    final cutStart = from > 0, cutEnd = to + 1 < sentences.length;
    final clipped = body.length > maxChars ? '${body.substring(0, maxChars)}…' : body;
    return '${cutStart ? '… ' : ''}$clipped${cutEnd && !clipped.endsWith('…') ? ' …' : ''}';
  }

  /// Цитаты, оформленные для сообщения: нумерация, текст в кавычках, источник под каждой.
  static String render(List<SourceQuote> quotes, {required String heading}) {
    if (quotes.isEmpty) return '';
    final b = StringBuffer('$heading\n');
    for (var i = 0; i < quotes.length; i++) {
      final q = quotes[i];
      final where = _clean(q.source) + (q.heading.isEmpty ? '' : ' — ${_section(q.heading)}');
      b.writeln('\n${i + 1}. «${q.text}»\n   — $where');
    }
    return b.toString().trimRight();
  }

  /// Раздел без повторения имени файла в начале (в базе заголовок хранится как «файл / раздел»).
  static String _section(String heading) {
    final i = heading.lastIndexOf(' / ');
    return i >= 0 ? heading.substring(i + 3) : heading;
  }

  static String _clean(String source) => source.replaceAll(RegExp(r'\.(pdf|docx|md|txt)$', caseSensitive: false), '').replaceAll('_', ' ');
}
