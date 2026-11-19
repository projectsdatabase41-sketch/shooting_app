import 'dart:convert';

import 'package:flutter/widgets.dart';
import '../i18n/i18n.dart';
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

  /// Пока переводчик в лимите — минуту его не дёргаем: иначе каждый экран
  /// получает 429 и пишет одинаковую ошибку в отзывы.
  static DateTime? _backoffUntil;

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
    if (res.statusCode == 429) {
      // Бесплатный переводчик часто отвечает «слишком много запросов».
      // Это не поломка приложения: молча пропускаем перевод и не засоряем
      // отзывы одинаковыми ошибками (их было больше половины выгрузки 19.11).
      _backoffUntil = DateTime.now().add(const Duration(minutes: 1));
      return null;
    }
    if (res.statusCode != 200) throw Exception(tr('Переводчик ответил {statusCode}', {'statusCode': res.statusCode}));
    final decoded = jsonDecode(utf8.decode(res.bodyBytes));
    if (decoded is! Map) return null;

    // MyMemory отвечает HTTP 200 даже когда сам перевод не удался —
    // например, автоопределённый язык текста совпал с целевым (сообщение
    // и так уже на нужном языке). Тогда responseStatus не "200"
    // (иногда строкой, иногда числом — сравниваем как строку), а в
    // translatedText лежит не перевод, а текст ошибки вида "PLEASE
    // SELECT TWO DISTINCT LANGUAGES" — не самих слов пользователя.
    if ('${decoded['responseStatus']}' != '200') return null;

    final data = decoded['responseData'];
    if (data is! Map) return null;

    final detected = '${data['detectedLanguage'] ?? ''}'.split('-').first.toLowerCase();
    if (detected.isNotEmpty && detected == target.toLowerCase()) return null;

    final translated = '${data['translatedText'] ?? ''}'.trim();
    return translated.isEmpty ? null : translated;
  }
}
