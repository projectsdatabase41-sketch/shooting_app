import 'dart:convert';
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/services.dart' show rootBundle;
import 'package:http/http.dart' as http;

import '../services/local_db_service.dart';

/// Перевод интерфейса словарями, где ключ — сам русский текст:
/// tr(«Удалить из контактов»), tr(«Удалить {n} сообщ.», {'n': n}) — в коде в одинарных кавычках.
///
/// Английский, немецкий и китайский встроены (assets/i18n/*.json); остальные
/// языки скачиваются по кнопке из репозитория (i18n/*.json) и хранятся в
/// локальной базе. Нет перевода — показывается русский текст. Словари
/// собирает и дополняет скрипт `dart run tool/i18n.dart`.
class I18n {
  I18n._();

  static const builtIn = {'en': 'English', 'de': 'Deutsch', 'zh': '中文'};

  /// Скачиваемые языки. ponytail: список в коде; перенести в удалённый
  /// конфиг, если языков станет много.
  static const downloadable = {
    'es': 'Español',
    'fr': 'Français',
    'it': 'Italiano',
    'pt': 'Português',
    'pl': 'Polski',
    'uk': 'Українська',
    'kk': 'Қазақша',
    'tr': 'Türkçe',
    'ja': '日本語',
    'ko': '한국어',
  };

  static const _repoRaw = 'https://raw.githubusercontent.com/projectsdatabase41-sketch/shooting_app/main/i18n';

  static String _code = 'ru';
  static Map<String, String> _dict = const {};

  /// Текущий язык интерфейса ('ru', 'en', …).
  static String get code => _code;

  /// Подгрузить словарь под выбор пользователя (null — язык устройства).
  static Future<void> apply(LocalDbService db, String? localeCode) async {
    final code = localeCode ?? PlatformDispatcher.instance.locale.languageCode;
    String? raw;
    try {
      if (builtIn.containsKey(code)) {
        raw = await rootBundle.loadString('assets/i18n/$code.json');
      } else if (downloadable.containsKey(code)) {
        raw = _stored(db, code);
      }
    } catch (_) {
      raw = null;
    }
    _dict = raw == null ? const {} : Map<String, String>.from(jsonDecode(raw) as Map);
    _code = raw == null ? 'ru' : code;
  }

  static String? _stored(LocalDbService db, String code) {
    final rows = db.db.select('SELECT hex FROM color_prefs WHERE key = ?', ['i18n_dict_$code']);
    return rows.isEmpty ? null : rows.first['hex'] as String?;
  }

  static bool isDownloaded(LocalDbService db, String code) => _stored(db, code) != null;

  /// Скачать словарь языка из репозитория. Бросает исключение, если его
  /// ещё нет или он битый.
  static Future<void> download(LocalDbService db, String code) async {
    final res = await http.get(Uri.parse('$_repoRaw/$code.json')).timeout(const Duration(seconds: 30));
    if (res.statusCode != 200) throw Exception('перевод на этот язык ещё не готов');
    final body = utf8.decode(res.bodyBytes);
    final decoded = jsonDecode(body);
    if (decoded is! Map || decoded.isEmpty) throw Exception('словарь пустой');
    db.db.execute(
      'INSERT INTO color_prefs (key, hex) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET hex = excluded.hex',
      ['i18n_dict_$code', body],
    );
  }
}

/// Перевод строки интерфейса. [ru] — русский текст (он же ключ словаря);
/// подстановки — `{имя}` в тексте и `args`.
String tr(String ru, [Map<String, Object?> args = const {}]) {
  var s = I18n._dict[ru] ?? ru;
  for (final e in args.entries) {
    s = s.replaceAll('{${e.key}}', '${e.value}');
  }
  return s;
}
