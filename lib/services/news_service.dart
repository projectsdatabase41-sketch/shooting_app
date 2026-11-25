import 'dart:convert';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:http/http.dart' as http;

import 'call_service.dart';
import 'local_db_service.dart';

/// Новостная лента: сервер раз в сутки собирает RSS в кэш R2, приложение
/// читает готовый JSON один раз при запуске. Поэтому число пользователей не
/// увеличивает нагрузку на RSS-источники — только на Cloudflare.
class NewsService {
  /// Последняя загруженная лента (память) и её время.
  static List<NewsItem> items = const [];
  static String? updatedAt;
  static DateTime? _fetchedAt;

  static const _kCache = 'news_feed_cache';

  static const _minInterval = Duration(minutes: 30);

  /// Итог последнего обновления. Экран по нему показывает короткое сообщение,
  /// но ленту не стирает: ошибка сети не должна оставлять пользователя с
  /// пустым экраном (отзыв владельца 23.11, п.2 — «загрузка долго длится.
  /// лучше запускать подгрузку новостей в фоне»).
  static bool lastRefreshFailed = false;

  /// Кладёт сохранённую ленту в [items] БЕЗ сети и возвращает true, если
  /// что-то нашлось. Экран зовёт это первым делом в initState: список
  /// рисуется сразу, а сервер догоняет в фоне (отзыв 23.11, п.2).
  static bool loadCached(LocalDbService db) {
    final rows = db.db.select('SELECT hex FROM color_prefs WHERE key = ?', [_kCache]);
    if (rows.isEmpty) return false;
    try {
      final data = jsonDecode('${rows.first['hex']}');
      if (data is! Map) return false;
      final list = _parseList(data['items']);
      if (list.isEmpty) return false;
      items = _clean(list);
      updatedAt = '${data['updatedAt'] ?? ''}';
      return true;
    } catch (_) {
      return false; // битый кэш не страшен — просто ждём сеть
    }
  }

  /// Забирает ленту с сервера. [force] — игнорировать паузу между запросами.
  /// Ошибки не пробрасываем: новости не должны мешать запуску приложения.
  ///
  /// Экран вызывает это в фоне и НЕ ждёт перед отрисовкой (отзыв 23.11, п.2):
  /// во время запроса показывается кэш, а не пустой экран.
  static Future<void> refresh({LocalDbService? db, bool force = false}) async {
    final now = DateTime.now();
    if (!force && _fetchedAt != null && now.difference(_fetchedAt!) < _minInterval) {
      // В паузу между запросами сеть не трогаем, значит и ошибки нет.
      lastRefreshFailed = false;
      return;
    }
    _fetchedAt = now;
    // Пока идёт сеть, показываем сохранённое (если экран ещё ничего не поднял).
    if (items.isEmpty && db != null) loadCached(db);
    try {
      final res = await http
          .get(Uri.parse('${CallService.url}/news'))
          .timeout(const Duration(seconds: 20));
      if (res.statusCode != 200) {
        // Кэш уже показан — оставляем его как есть.
        lastRefreshFailed = true;
        return;
      }
      final data = jsonDecode(utf8.decode(res.bodyBytes));
      if (data is! Map) {
        lastRefreshFailed = true;
        return;
      }
      final list = _parseList(data['items']);
      // Сервер отдал пустой список — это не повод затирать показанное.
      if (list.isEmpty) return;
      items = _clean(list);
      updatedAt = '${data['updatedAt'] ?? ''}';
      lastRefreshFailed = false;
      if (db != null) {
        db.db.execute(
          'INSERT INTO color_prefs (key, hex) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET hex = excluded.hex',
          [_kCache, jsonEncode({'updatedAt': updatedAt, 'items': [
            for (final i in list)
              {'title': i.title, 'link': i.link, 'source': i.source, 'date': i.date, 'summary': i.summary, 'image': i.image}
          ]})],
        );
      }
    } catch (_) {
      // Сеть отвалилась: ленту из памяти/кэша не трогаем (отзыв 23.11, п.2),
      // только запоминаем, что за это обновление обновить не удалось.
      lastRefreshFailed = true;
    }
  }

  static List<NewsItem> _parseList(Object? raw) => (raw as List? ?? const [])
      .whereType<Map>()
      .map((m) => NewsItem(
            title: '${m['title'] ?? ''}',
            link: '${m['link'] ?? ''}',
            source: '${m['source'] ?? ''}',
            image: '${m['image'] ?? ''}',
            date: '${m['date'] ?? ''}',
            summary: '${m['summary'] ?? ''}',
          ))
      .where((i) => i.title.isNotEmpty)
      .toList();

  // Отзыв 25.11 (eabeec17): дубли из двух источников.
  /// Лента собирается из двух источников: воркер отдаёт сетевой ответ, а
  /// до его прихода показан кэш — одну и ту же новость разные источники
  /// дают с разными хвостами ссылки или слегка разными заголовками.
  /// Убираем дубликаты по нормализованной ссылке и по заголовку, оставляя
  /// первый (самый свежий) экземпляр, и сортируем по дате — новые сверху.
  /// Дата приходит строкой: парсим мягко (DateTime.tryParse), существующий
  /// показ (`_shortDate` в news_screen.dart обрезает первые 10 символов)
  /// не меняется, непарсируемые даты уходят в конец с исходным порядком.
  static List<NewsItem> _clean(List<NewsItem> list) => dedupe(list);

  /// То же, что внутренняя чистка ленты, но доступно тестам: дедупликация
  /// по ссылке/заголовку и сортировка по дате (отзыв 25.11, eabeec17).
  @visibleForTesting
  static List<NewsItem> dedupe(List<NewsItem> list) {
    final seenLinks = <String>{};
    final seenTitles = <String>{};
    final unique = <NewsItem>[];
    for (final n in list) {
      final link = _linkKey(n.link);
      if (link.isNotEmpty && !seenLinks.add(link)) continue;
      if (!seenTitles.add(_titleKey(n.title))) continue;
      unique.add(n);
    }
    final stamps = [
      for (final n in unique)
        _dateMs(n.date) ??
            // Без даты — в конец. Число обязано точно представиться в
            // JavaScript: 2^53−1 — максимум безопасного целого (веб-сборка
            // падала на 0x7fffffffffffffff, отзыв 25.11).
            -9007199254740991
    ];
    final order = List<int>.generate(unique.length, (i) => i);
    // Dart-сортировка нестабильна, поэтому при равных датах сохраняем
    // исходный порядок по индексу.
    order.sort((a, b) {
      final byDate = stamps[b].compareTo(stamps[a]); // новые сверху
      return byDate != 0 ? byDate : a.compareTo(b);
    });
    return [for (final i in order) unique[i]];
  }

  /// Дата новости → миллисекунды UTC. Лента приходит в формате RSS/RFC-822
  /// («Tue, 24 Nov 2026 10:00:00 +0000»), который `DateTime.parse` не
  /// понимает: до этой правки все даты выходили null и сортировка по дате
  /// фактически не работала (отзыв eabeec17).
  static int? _dateMs(String raw) {
    final iso = DateTime.tryParse(raw);
    if (iso != null) return iso.millisecondsSinceEpoch;
    final m = RegExp(
            r'(\d{1,2})\s+([A-Za-z]{3})[A-Za-z]*\s+(\d{4})[ T](\d{1,2}):(\d{2})(?::(\d{2}))?\s*([+-]\d{4})?')
        .firstMatch(raw);
    if (m == null) return null;
    const months = {
      'jan': 1, 'feb': 2, 'mar': 3, 'apr': 4, 'may': 5, 'jun': 6,
      'jul': 7, 'aug': 8, 'sep': 9, 'oct': 10, 'nov': 11, 'dec': 12,
    };
    final mon = months[m.group(2)!.toLowerCase()];
    if (mon == null) return null;
    var dt = DateTime.utc(
      int.parse(m.group(3)!),
      mon,
      int.parse(m.group(1)!),
      int.parse(m.group(4)!),
      int.parse(m.group(5)!),
      int.tryParse(m.group(6) ?? '') ?? 0,
    );
    final off = m.group(7);
    if (off != null && off.length == 5) {
      final sign = off.startsWith('-') ? -1 : 1;
      final h = int.parse(off.substring(1, 3));
      final min = int.parse(off.substring(3, 5));
      dt = dt.subtract(Duration(minutes: sign * (h * 60 + min)));
    }
    return dt.millisecondsSinceEpoch;
  }

  /// Ключ ссылки: нижний регистр, без схемы, www и завершающих слэшей,
  /// query-хвосты вида ?utm_... выбрасываются — ссылку из двух источников
  /// узнаём как одну.
  static String _linkKey(String raw) {
    var s = raw.trim().toLowerCase();
    if (s.isEmpty) return s;
    s = s.replaceFirst(RegExp(r'^(https?:)?//'), '');
    s = s.replaceFirst(RegExp(r'^www\.'), '');
    final hash = s.indexOf('#');
    if (hash >= 0) s = s.substring(0, hash);
    final q = s.indexOf('?');
    if (q >= 0) {
      final kept = s
          .substring(q + 1)
          .split('&')
          .where((p) => p.isNotEmpty && !p.startsWith('utm_'))
          .join('&');
      s = '${s.substring(0, q)}${kept.isEmpty ? '' : '?$kept'}';
    }
    while (s.endsWith('/')) {
      s = s.substring(0, s.length - 1);
    }
    return s;
  }

  /// Ключ заголовка: без регистра и пробелов — один и тот же заголовок от
  /// разных источников сравниваем как один.
  static String _titleKey(String raw) =>
      raw.toLowerCase().replaceAll(RegExp(r'\s+'), '');
}

/// Клиентский фильтр ленты: источники чекбоксами + слова по заголовку и
/// summary. Живёт в той же key-value таблице `color_prefs`, что и кэш ленты
/// (отдельную таблицу под настройки не заводим) — отзыв владельца 23.11, п.1:
/// «какие фильтры новостей стоят? хотелось бы их выбирать».
class NewsFilter {
  /// Пустой набор = все источники. Пустая строка слов = без поиска.
  final Set<String> sources;
  final String words;

  const NewsFilter({this.sources = const <String>{}, this.words = ''});

  /// Ключи настроек в `color_prefs` (механизм тот же, что у кэша ленты).
  static const keySources = 'news_filter_sources';
  static const keyWords = 'news_filter_words';

  bool get isActive => sources.isNotEmpty || words.trim().isNotEmpty;

  static NewsFilter load(LocalDbService db) {
    String read(String key) {
      final rows = db.db.select('SELECT hex FROM color_prefs WHERE key = ?', [key]);
      return rows.isEmpty ? '' : '${rows.first['hex'] ?? ''}';
    }

    final sources = read(keySources)
        .split('\n')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toSet();
    return NewsFilter(sources: sources, words: read(keyWords).trim());
  }

  void save(LocalDbService db) {
    void put(String key, String value) => db.db.execute(
          'INSERT INTO color_prefs (key, hex) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET hex = excluded.hex',
          [key, value],
        );
    // Источники — построчно: в названиях бывают запятые и точки.
    put(keySources, sources.join('\n'));
    put(keyWords, words.trim());
  }

  /// Кириллица: `String.toLowerCase()` в Dart работает и для неё, а
  /// `contains(..., caseSensitive: false)` — нет, поэтому приводим обе
  /// стороны к нижнему регистру и ищем подстрокой (без RegExp: в вводе
  /// пользователя могут оказаться спецсимволы).
  ///
  /// Несколько слов через пробел — все должны найтись (п.1 отзыва 23.11:
  /// «поле слова»).
  bool matches(NewsItem n) {
    if (sources.isNotEmpty && !sources.contains(n.source)) return false;
    final tokens = words
        .toLowerCase()
        .split(RegExp(r'\s+'))
        .where((t) => t.isNotEmpty)
        .toList();
    if (tokens.isEmpty) return true;
    final hay = '${n.title}\n${n.summary}'.toLowerCase();
    for (final t in tokens) {
      if (!hay.contains(t)) return false;
    }
    return true;
  }
}

class NewsItem {
  final String title;
  final String link;
  final String source;
  final String date;
  final String summary;
  final String image;
  const NewsItem({
    required this.title,
    required this.link,
    required this.source,
    required this.date,
    required this.summary,
    this.image = '',
  });
}
