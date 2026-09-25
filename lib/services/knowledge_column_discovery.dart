import 'dart:convert';

import 'package:http/http.dart' as http;

import 'ai_service.dart';
import 'local_db_service.dart';

/// Определяет, какая колонка подключённой таблицы содержит основной
/// текст для поиска — решение пользователя вместо угадывания
/// (раньше все таблицы, и вшитые, и личные, по умолчанию искали в
/// колонке `content`, а у "правил" и у самостоятельно подключённых
/// таблиц вроде "заметок" она называется иначе, и поиск молча ничего
/// не находил):
///
/// 1. Берём одну строку таблицы — её ключи и есть список колонок.
/// 2. Отдаём этот список ИИ с вопросом "какая колонка — основной текст".
/// 3. Кешируем ответ здесь, чтобы не спрашивать заново на каждый поиск.
///
/// Запись стирается при отключении таблицы (`forget`) — если её
/// подключат снова (в том числе таблицу с тем же именем, но другой
/// структурой), колонку определяют заново, а не доверяют старому кешу.
class KnowledgeColumnDiscovery {
  final LocalDbService db;
  KnowledgeColumnDiscovery(this.db);

  String? cachedContentColumn(String tableName) {
    final rows = db.db.select('SELECT content_column FROM ai_knowledge_columns WHERE table_name = ?', [tableName]);
    return rows.isEmpty ? null : rows.first['content_column'] as String;
  }

  /// Все колонки таблицы, как они были видны при определении основной
  /// (`null`, если таблицу ещё не определяли).
  List<String>? cachedAllColumns(String tableName) {
    final rows = db.db.select('SELECT all_columns FROM ai_knowledge_columns WHERE table_name = ?', [tableName]);
    if (rows.isEmpty) return null;
    try {
      return (jsonDecode(rows.first['all_columns'] as String) as List).map((e) => '$e').toList();
    } catch (_) {
      return null;
    }
  }

  void forget(String tableName) {
    db.db.execute('DELETE FROM ai_knowledge_columns WHERE table_name = ?', [tableName]);
  }

  /// `null`, если определить не удалось (таблица пуста, сеть
  /// недоступна, ИИ не смог выбрать из списка) — вызывающий код в этом
  /// случае откатывается на дефолт `content`, ничего не ломается.
  Future<String?> discover({
    required String tableName,
    required String baseUrl,
    required String token,
    required AiService aiService,
    http.Client Function()? clientFactory,
  }) async {
    final cached = cachedContentColumn(tableName);
    if (cached != null) return cached;

    final columns = await _fetchSampleColumns(tableName, baseUrl, token, clientFactory);
    if (columns == null || columns.isEmpty) return null;

    try {
      final reply = await aiService.ask(
        task: 'knowledge_columns',
        systemPrompt: 'Ты помогаешь приложению для стрельбы понять структуру ЧУЖОЙ таблицы базы '
            'данных, которую подключил пользователь. Дан список имён колонок ОДНОЙ таблицы. '
            'Определи, какая ОДНА колонка содержит основной свободный текст (заметку, правило, '
            'описание, содержимое) — по нему ассистент будет искать текстом. Не выбирай служебные '
            'колонки вроде id, даты, внешних ключей. Ответь СТРОГО одним именем колонки из списка, '
            'без пояснений и без кавычек.',
        contextBlock: 'Колонки таблицы "$tableName": ${columns.join(", ")}',
        history: const [(role: 'user', text: 'Какая колонка содержит основной текст?')],
      );
      final picked = reply.text.trim();
      if (!columns.contains(picked)) return null;
      _save(tableName, picked, columns);
      return picked;
    } catch (_) {
      return null;
    }
  }

  Future<List<String>?> _fetchSampleColumns(
    String tableName,
    String baseUrl,
    String token,
    http.Client Function()? clientFactory,
  ) async {
    final client = (clientFactory ?? http.Client.new)();
    try {
      final uri = Uri.parse('$baseUrl/$tableName').replace(queryParameters: {'select': '*', 'limit': '1'});
      final res = await client.get(uri, headers: {
        'apikey': token,
        'Authorization': 'Bearer $token',
      }).timeout(const Duration(seconds: 20));
      if (res.statusCode != 200) return null;
      final decoded = jsonDecode(utf8.decode(res.bodyBytes));
      if (decoded is! List || decoded.isEmpty) return null;
      final row = decoded.first;
      if (row is! Map) return null;
      return row.keys.map((k) => '$k').toList();
    } catch (_) {
      return null;
    } finally {
      client.close();
    }
  }

  void _save(String tableName, String contentColumn, List<String> allColumns) {
    db.db.execute(
      'INSERT INTO ai_knowledge_columns (table_name, content_column, all_columns, discovered_at) '
      'VALUES (?, ?, ?, ?) '
      'ON CONFLICT(table_name) DO UPDATE SET content_column = excluded.content_column, '
      'all_columns = excluded.all_columns, discovered_at = excluded.discovered_at',
      [tableName, contentColumn, jsonEncode(allColumns), DateTime.now().toIso8601String()],
    );
  }
}
