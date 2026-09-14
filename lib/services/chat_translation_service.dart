import 'package:flutter/widgets.dart';

import 'ai_service.dart';
import 'ai_settings.dart';

/// Перевод сообщений чата (пункт 4 списка правок) — через уже
/// встроенного ИИ-ассистента (тот же ключ/цепочка моделей OpenRouter),
/// а не отдельный переводческий API: меньше кода, меньше зависимостей.
class ChatTranslationService {
  final AiService _ai;
  ChatTranslationService(AiSettings settings) : _ai = AiService(settings);

  /// Язык устройства (ISO 639-1, например "ru"/"en") — с ним сравнивают
  /// "не язык системы" из настройки перевода.
  static String systemLanguageCode() =>
      WidgetsBinding.instance.platformDispatcher.locale.languageCode;

  static const String _sameMarker = 'РАВНО';

  /// `null`, если текст уже на языке устройства (переводить нечего) —
  /// одним запросом просим модель и определить язык, и перевести, чтобы
  /// не делать два похода к ИИ на каждое сообщение.
  Future<String?> translateIfNeeded(String text) async {
    final lang = systemLanguageCode();
    final reply = await _ai.ask(
      systemPrompt:
          'Ты — переводчик. Тебе дают одно сообщение из чата. Если оно УЖЕ на языке '
          'с кодом ISO 639-1 "$lang" — ответь ровно одним словом: $_sameMarker (без кавычек и '
          'пояснений). Если оно на другом языке — переведи его на язык "$lang" и ответь '
          'ТОЛЬКО переводом, без кавычек и пояснений.',
      contextBlock: '',
      history: [(role: 'user', text: text)],
    );
    final result = reply.text.trim();
    if (result.isEmpty || result == _sameMarker) return null;
    return result;
  }
}
