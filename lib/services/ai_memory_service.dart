import 'dart:convert';

import 'package:http/http.dart' as http;

import '../logic/text_search.dart';
import '../models/ai_memory_summary.dart';
import 'supabase_auth_service.dart';

class AiMemoryException implements Exception {
  final String message;
  const AiMemoryException(this.message);
  @override
  String toString() => message;
}

/// Хранит и читает сводки прошлых разговоров с ассистентом — в ЛИЧНОЙ
/// базе спортсмена (`ai_conversation_summaries`, sql/schema.sql), той
/// же, куда синхронизируются тренировки. НЕ путать с `KnowledgeService`
/// — та ищет по публичной таблице справочных материалов общую для всех
/// пользователей, а не по личным данным конкретного человека, и не
/// требует входа.
///
/// Молчит, если пользователь не подключил облако вовсе — тогда
/// ассистент просто не помнит прошлых разговоров, как и раньше, это не
/// ошибка, а нормальный офлайн-режим приложения.
class AiMemoryService {
  final SupabaseAuthService auth;
  final http.Client Function() clientFactory;

  AiMemoryService(this.auth, {http.Client Function()? clientFactory})
      : clientFactory = clientFactory ?? http.Client.new;

  /// Сколько последних записей вообще держим под рукой для поиска —
  /// тот самый "ограниченный ~200 строк" из первоначального вопроса
  /// пользователя про RAG-память. Тянем их одним запросом (дёшево —
  /// строки короткие) и ранжируем по ключевым словам ЛОКАЛЬНО, а не
  /// шлём отдельный запрос в базу на каждое слово, как делает
  /// `KnowledgeService` для куда более крупной таблицы книг.
  static const int _recentWindow = 200;

  Future<List<AiMemorySummary>> _fetchRecent({int limit = _recentWindow}) async {
    if (!auth.isSignedIn) return const [];
    final token = await auth.ensureFreshToken();
    if (token == null) return const [];
    final client = clientFactory();
    try {
      final res = await client.get(
        Uri.parse('${auth.url}/rest/v1/ai_conversation_summaries'
            '?select=id,period_start,period_end,summary,training_package_ids'
            '&order=period_start.desc&limit=$limit'),
        headers: {
          'apikey': auth.anonKey,
          'Authorization': 'Bearer $token',
        },
      ).timeout(const Duration(seconds: 20));
      if (res.statusCode >= 400) return const [];
      final decoded = jsonDecode(utf8.decode(res.bodyBytes));
      if (decoded is! List) return const [];
      return decoded.cast<Map<String, dynamic>>().map(AiMemorySummary.fromJson).toList();
    } catch (_) {
      // Сеть недоступна — молча без памяти о прошлом, не ошибка чата.
      return const [];
    } finally {
      client.close();
    }
  }

  /// Последние записи как есть, самые свежие первыми — например, для
  /// экрана "посмотреть память" (если такой появится). Большинству
  /// вызывающего кода нужен `search()`, не этот метод.
  Future<List<AiMemorySummary>> recent({int limit = 20}) => _fetchRecent(limit: limit);

  /// Записи, релевантные вопросу — по ключевым словам (`TextSearch`,
  /// та же логика, что у `KnowledgeService.search`), а не слепые
  /// "последние N" (решение пользователя: "лучше в раг каждый запрос
  /// записывает... можно поиск по ключевым словам реализовать" — было
  /// вернуть последние 20 сводок независимо от темы вопроса).
  ///
  /// Пустой список — вопрос слишком короткий/это болтовня, облако не
  /// подключено, или ничего подходящего не нашлось: во всех случаях
  /// ассистент просто не упоминает прошлое, это не ошибка.
  Future<List<AiMemorySummary>> search(String question, {int limit = 5}) async {
    final trimmed = question.trim();
    if (trimmed.length < TextSearch.minQuestionLength) return const [];
    if (TextSearch.isSmallTalk(trimmed)) return const [];
    final words = TextSearch.keywords(trimmed);
    if (words.isEmpty) return const [];

    final pool = await _fetchRecent();
    final ranked = pool.where((s) => TextSearch.relevance(s.summary, words) > 0).toList()
      ..sort((a, b) => TextSearch.relevance(b.summary, words).compareTo(TextSearch.relevance(a.summary, words)));
    return ranked.take(limit).toList();
  }

  /// Добавляет новую сводку. Молча ничего не делает без облака —
  /// вызывающий код (`AiChatViewModel`) не должен ронять сам разговор
  /// из-за того, что подведение итога не сохранилось.
  Future<void> append(AiMemorySummary summary) async {
    if (!auth.isSignedIn) return;
    final token = await auth.ensureFreshToken();
    if (token == null) return;
    final client = clientFactory();
    try {
      await client
          .post(
            Uri.parse('${auth.url}/rest/v1/ai_conversation_summaries'),
            headers: {
              'apikey': auth.anonKey,
              'Authorization': 'Bearer $token',
              'Content-Type': 'application/json',
              'Prefer': 'return=minimal',
            },
            body: jsonEncode([summary.toJson()]),
          )
          .timeout(const Duration(seconds: 20));
    } catch (_) {
      // Best-effort — см. комментарий у метода.
    } finally {
      client.close();
    }
  }
}
