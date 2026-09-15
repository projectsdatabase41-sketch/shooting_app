import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;

/// Перевод сообщений чата (пункт 4 списка правок) — намеренно БЕЗ
/// нашего ИИ-ассистента (решение пользователя: "не подключай к нашему
/// ИИ, а то лимит сожрём быстро" — у OpenRouter общий дневной лимит на
/// бесплатные модели, шаренный со всем остальным ассистентом).
///
/// Использован бесплатный API MyMemory (mymemory.translated.net) — без
/// ключа, без регистрации, с автоопределением языка исходного текста.
/// Раньше здесь был неофициальный endpoint Google Translate (`gtx`), но
/// он работает только там, где нет CORS (нативные сборки) — в вебе
/// браузер блокирует fetch к translate.googleapis.com (нет заголовков
/// Access-Control-Allow-Origin), запрос падает с "Failed to fetch".
/// MyMemory отдаёт CORS-заголовки и работает одинаково везде.
class ChatTranslationService {
  final http.Client _client;
  ChatTranslationService({http.Client? client}) : _client = client ?? http.Client();

  static const Duration _timeout = Duration(seconds: 10);

  /// Язык устройства (ISO 639-1, например "ru"/"en") — с ним сравнивают
  /// "не язык системы" из настройки перевода.
  static String systemLanguageCode() => WidgetsBinding.instance.platformDispatcher.locale.languageCode;

  /// `null`, если определённый язык текста и так совпадает с целевым
  /// (переводить нечего). [targetLanguage] — код языка перевода, обычно
  /// из настроек чата (`ChatPreferences.translationLanguage`, пусто —
  /// язык системы).
  Future<String?> translateIfNeeded(String text, {required String targetLanguage}) async {
    final target = targetLanguage.isEmpty ? systemLanguageCode() : targetLanguage;
    final uri = Uri.https('api.mymemory.translated.net', '/get', {
      'q': text,
      'langpair': 'autodetect|$target',
    });
    final res = await _client.get(uri).timeout(_timeout);
    if (res.statusCode != 200) throw Exception('Переводчик ответил ${res.statusCode}');
    final decoded = jsonDecode(utf8.decode(res.bodyBytes));
    if (decoded is! Map) return null;

    final data = decoded['responseData'];
    if (data is! Map) return null;

    final detected = '${data['detectedLanguage'] ?? ''}'.split('-').first.toLowerCase();
    if (detected.isNotEmpty && detected == target.toLowerCase()) return null;

    final translated = '${data['translatedText'] ?? ''}'.trim();
    return translated.isEmpty ? null : translated;
  }
}
