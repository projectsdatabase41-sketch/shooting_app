import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;

/// Перевод сообщений чата (пункт 4 списка правок) — намеренно БЕЗ
/// нашего ИИ-ассистента (решение пользователя: "не подключай к нашему
/// ИИ, а то лимит сожрём быстро" — у OpenRouter общий дневной лимит на
/// бесплатные модели, шаренный со всем остальным ассистентом).
///
/// Использован тот же бесплатный endpoint Google Translate (`gtx`),
/// на котором построены популярные open-source библиотеки перевода
/// (googletrans и т.п.) — без ключа, без регистрации, с автоопределением
/// языка исходного текста. Неофициальный (это не публичный Cloud
/// Translation API), поэтому асинхронно может измениться на стороне
/// Google — если это когда-нибудь случится, перевод просто перестанет
/// работать (сообщение останется без маски), это не уронит остальной чат.
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
    final uri = Uri.https('translate.googleapis.com', '/translate_a/single', {
      'client': 'gtx',
      'sl': 'auto',
      'tl': target,
      'dt': 't',
      'q': text,
    });
    final res = await _client.get(uri).timeout(_timeout);
    if (res.statusCode != 200) throw Exception('Переводчик ответил ${res.statusCode}');
    final decoded = jsonDecode(utf8.decode(res.bodyBytes));
    if (decoded is! List || decoded.isEmpty) return null;

    final detected = decoded.length > 2 ? '${decoded[2]}' : null;
    if (detected != null && detected == target) return null;

    final segments = decoded[0];
    if (segments is! List) return null;
    final translated = segments.map((s) => s is List && s.isNotEmpty ? '${s[0]}' : '').join();
    return translated.trim().isEmpty ? null : translated.trim();
  }
}
