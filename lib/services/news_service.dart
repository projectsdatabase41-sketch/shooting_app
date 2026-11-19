import 'dart:convert';

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

  /// Забирает ленту с сервера. [force] — игнорировать паузу между запросами.
  /// Ошибки не пробрасываем: новости не должны мешать запуску приложения.
  static Future<void> refresh({LocalDbService? db, bool force = false}) async {
    final now = DateTime.now();
    if (!force && _fetchedAt != null && now.difference(_fetchedAt!) < _minInterval) return;
    _fetchedAt = now;
    try {
      final res = await http
          .get(Uri.parse('${CallService.url}/news'))
          .timeout(const Duration(seconds: 20));
      if (res.statusCode != 200) {
        if (items.isEmpty && db != null) _loadCached(db);
        return;
      }
      final data = jsonDecode(utf8.decode(res.bodyBytes));
      if (data is! Map) return;
      final list = (data['items'] as List? ?? const [])
          .whereType<Map>()
          .map((m) => NewsItem(
                title: '${m['title'] ?? ''}',
                link: '${m['link'] ?? ''}',
                source: '${m['source'] ?? ''}',
                date: '${m['date'] ?? ''}',
                summary: '${m['summary'] ?? ''}',
              ))
          .where((i) => i.title.isNotEmpty)
          .toList();
      if (list.isEmpty) return;
      items = list;
      updatedAt = '${data['updatedAt'] ?? ''}';
      if (db != null) {
        db.db.execute(
          'INSERT INTO color_prefs (key, hex) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET hex = excluded.hex',
          [_kCache, jsonEncode({'updatedAt': updatedAt, 'items': [
            for (final i in list)
              {'title': i.title, 'link': i.link, 'source': i.source, 'date': i.date, 'summary': i.summary}
          ]})],
        );
      }
    } catch (_) {
      if (items.isEmpty && db != null) _loadCached(db);
    }
  }

  /// Показывает сохранённую ленту, если сети нет — экран не пустой.
  static void _loadCached(LocalDbService db) {
    final rows = db.db.select('SELECT hex FROM color_prefs WHERE key = ?', [_kCache]);
    if (rows.isEmpty) return;
    try {
      final data = jsonDecode('${rows.first['hex']}');
      if (data is! Map) return;
      items = (data['items'] as List? ?? const [])
          .whereType<Map>()
          .map((m) => NewsItem(
                title: '${m['title'] ?? ''}',
                link: '${m['link'] ?? ''}',
                source: '${m['source'] ?? ''}',
                date: '${m['date'] ?? ''}',
                summary: '${m['summary'] ?? ''}',
              ))
          .toList();
      updatedAt = '${data['updatedAt'] ?? ''}';
    } catch (_) {}
  }
}

class NewsItem {
  final String title;
  final String link;
  final String source;
  final String date;
  final String summary;
  const NewsItem({
    required this.title,
    required this.link,
    required this.source,
    required this.date,
    required this.summary,
  });
}
