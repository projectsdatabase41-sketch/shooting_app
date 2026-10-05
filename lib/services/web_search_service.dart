import 'dart:convert';

import 'package:http/http.dart' as http;

import 'ai_settings.dart';

/// Поиск в интернете с ответом ИИ прямо в приложении: Gemini с
/// инструментом «Google Search» (grounding) сам ищет, читает страницы и
/// пишет ответ со ссылками на источники. Нужен собственный бесплатный
/// ключ Gemini (aistudio.google.com) — `AiSettings.geminiKey`.
class WebSearchService {
  final AiSettings settings;
  final http.Client Function() clientFactory;
  WebSearchService(this.settings, {http.Client Function()? clientFactory})
      : clientFactory = clientFactory ?? http.Client.new;

  /// Список по очереди: если у ключа нет доступа к первой модели (404) —
  /// пробуем следующую.
  static const models = ['gemini-2.5-flash', 'gemini-2.0-flash'];

  bool get configured => settings.geminiKey.isNotEmpty;

  Future<({String text, List<({String title, String url})> sources})> search(
      String query) async {
    if (!configured) throw StateError('no key');
    Object? lastError;
    for (final model in models) {
      final client = clientFactory();
      try {
        final res = await client
            .post(
              Uri.parse(
                  'https://generativelanguage.googleapis.com/v1beta/models/$model:generateContent'),
              headers: {
                'Content-Type': 'application/json',
                'x-goog-api-key': settings.geminiKey
              },
              body: jsonEncode({
                'systemInstruction': {
                  'parts': [
                    {
                      'text': 'Ты ищешь в интернете и отвечаешь на вопрос пользователя по найденному. '
                          'Отвечай на языке вопроса, по делу, без воды; если данные расходятся — скажи об этом.',
                    }
                  ],
                },
                'contents': [
                  {
                    'role': 'user',
                    'parts': [
                      {'text': query},
                    ],
                  },
                ],
                'tools': [
                  {'google_search': {}},
                ],
              }),
            )
            .timeout(const Duration(seconds: 60));
        if (res.statusCode == 404) {
          lastError = 'HTTP 404 ($model)';
          continue;
        }
        if (res.statusCode >= 400) {
          throw Exception(
              'HTTP ${res.statusCode}: ${utf8.decode(res.bodyBytes).split('\n').take(3).join(' ')}');
        }
        return parse(jsonDecode(utf8.decode(res.bodyBytes)));
      } finally {
        client.close();
      }
    }
    throw Exception('$lastError');
  }

  /// Отдельно от сети — чтобы разбор ответа проверялся тестом.
  static ({String text, List<({String title, String url})> sources}) parse(
      dynamic json) {
    final cands =
        (json is Map ? json['candidates'] : null) as List? ?? const [];
    if (cands.isEmpty) throw Exception('Пустой ответ поиска');
    final cand = cands.first as Map;
    final parts = ((cand['content'] as Map?)?['parts'] as List?) ?? const [];
    final text = parts.map((p) => (p as Map)['text'] ?? '').join().trim();
    final chunks =
        ((cand['groundingMetadata'] as Map?)?['groundingChunks'] as List?) ??
            const [];
    final seen = <String>{};
    final sources = <({String title, String url})>[];
    for (final c in chunks) {
      final web = (c as Map)['web'] as Map?;
      final url = '${web?['uri'] ?? ''}';
      if (url.isEmpty || !seen.add(url)) continue;
      sources.add((title: '${web?['title'] ?? url}', url: url));
    }
    if (text.isEmpty) throw Exception('Поиск не вернул текст');
    return (text: text, sources: sources);
  }
}
