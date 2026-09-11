import 'dart:convert';

import 'package:http/http.dart' as http;

import 'ai_settings.dart';

/// Отправка анонимного отзыва об приложении в общую базу разработчика
/// (та же, что книги/правила стрельбы, `AiSettings.booksUrl`) — пункт 10
/// списка правок. Отзыв пишет ассистент по явной просьбе пользователя
/// (см. `AiContext.systemPrompt`, блок ```feedback), без имени и прочих
/// личных данных — таблица нарочно хранит только текст, никаких "кто" и
/// "откуда".
class FeedbackService {
  final http.Client _client;
  FeedbackService({http.Client? client}) : _client = client ?? http.Client();

  Future<void> send(String text) async {
    final res = await _client
        .post(
          Uri.parse('${AiSettings.booksUrl}/feedback'),
          headers: {
            'apikey': AiSettings.booksToken,
            'Authorization': 'Bearer ${AiSettings.booksToken}',
            'Content-Type': 'application/json',
          },
          body: jsonEncode({'text': text}),
        )
        .timeout(const Duration(seconds: 20));
    if (res.statusCode >= 300) {
      throw Exception('Не удалось отправить отзыв (${res.statusCode})');
    }
  }
}
