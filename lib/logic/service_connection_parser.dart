import 'dart:convert';

/// Разобранное подключение — общий результат для всех трёх способов
/// ввода на экране "Добавить сервис".
class ParsedConnection {
  final String url;
  final String method;
  final Map<String, String> headers;
  final String? body;

  const ParsedConnection({required this.url, this.method = 'GET', this.headers = const {}, this.body});
}

class ServiceConnectionParser {
  const ServiceConnectionParser._();

  /// Просто URL — самый частый случай (Google Диск, дашборд Supabase,
  /// заметки и т.п., решение пользователя): открывается как обычная
  /// ссылка, без заголовков и метода.
  static ParsedConnection fromUrl(String input) {
    final url = input.trim();
    if (url.isEmpty) throw const FormatException('Пустая ссылка');
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      throw const FormatException('Ссылка должна начинаться с http:// или https://');
    }
    return ParsedConnection(url: url);
  }

  /// `{"url": "...", "method": "GET", "headers": {...}, "body": "..."}` —
  /// удобно, если API уже описан где-то в этом виде (например, скопирован
  /// из своих же заметок или сгенерирован ассистентом).
  static ParsedConnection fromJson(String input) {
    final Object? decoded;
    try {
      decoded = jsonDecode(input);
    } catch (_) {
      throw const FormatException('Не похоже на JSON');
    }
    if (decoded is! Map) throw const FormatException('JSON должен быть объектом {...}');
    final url = decoded['url'];
    if (url is! String || url.isEmpty) throw const FormatException('В JSON нет поля "url"');
    final headersRaw = decoded['headers'];
    final headers = <String, String>{
      if (headersRaw is Map) for (final e in headersRaw.entries) '${e.key}': '${e.value}',
    };
    final bodyRaw = decoded['body'];
    return ParsedConnection(
      url: url,
      method: '${decoded['method'] ?? (bodyRaw != null ? 'POST' : 'GET')}'.toUpperCase(),
      headers: headers,
      body: bodyRaw == null ? null : (bodyRaw is String ? bodyRaw : jsonEncode(bodyRaw)),
    );
  }

  /// Разбирает команду `curl ...` — из тех, что копирует кнопка "Copy as
  /// cURL" в devtools браузера или показывает документация API. Не
  /// полноценный шелл-парсер (не поддерживает `$переменные`, пайпы и
  /// т.п.) — только то, что реально попадается в таких командах: кавычки
  /// (одинарные/двойные), `-H`/`--header`, `-X`/`--request`,
  /// `-d`/`--data`/`--data-raw`, и сам URL первым «голым» аргументом.
  static ParsedConnection fromCurl(String input) {
    final tokens = _tokenize(input.trim());
    if (tokens.isEmpty || tokens.first.toLowerCase() != 'curl') {
      throw const FormatException('Команда должна начинаться с "curl"');
    }

    String? url;
    String? method;
    String? body;
    final headers = <String, String>{};

    for (var i = 1; i < tokens.length; i++) {
      final t = tokens[i];
      switch (t) {
        case '-H':
        case '--header':
          if (i + 1 < tokens.length) {
            final parts = tokens[++i].split(':');
            if (parts.length >= 2) headers[parts.first.trim()] = parts.sublist(1).join(':').trim();
          }
        case '-X':
        case '--request':
          if (i + 1 < tokens.length) method = tokens[++i].toUpperCase();
        case '-d':
        case '--data':
        case '--data-raw':
        case '--data-binary':
          if (i + 1 < tokens.length) body = tokens[++i];
        default:
          // Первый аргумент без "-" в начале — это и есть URL (флаги
          // вроде -s/-L/--compressed просто пропускаем молча).
          if (url == null && !t.startsWith('-')) url = t;
      }
    }

    if (url == null || url.isEmpty) throw const FormatException('Не нашёл ссылку в команде curl');
    return ParsedConnection(
      url: url,
      method: method ?? (body != null ? 'POST' : 'GET'),
      headers: headers,
      body: body,
    );
  }

  /// Простой токенайзер с поддержкой одинарных/двойных кавычек — этого
  /// достаточно для реальных cURL-команд из документации/devtools, куда
  /// более сложный синтаксис (переменные, экранирование внутри кавычек)
  /// в них попадает редко.
  static List<String> _tokenize(String input) {
    final tokens = <String>[];
    final buffer = StringBuffer();
    String? quote;
    for (var i = 0; i < input.length; i++) {
      final c = input[i];
      if (quote != null) {
        if (c == quote) {
          quote = null;
        } else {
          buffer.write(c);
        }
        continue;
      }
      if (c == '"' || c == "'") {
        quote = c;
        continue;
      }
      if (c == ' ' || c == '\n' || c == '\t') {
        if (buffer.isNotEmpty) {
          tokens.add(buffer.toString());
          buffer.clear();
        }
        continue;
      }
      // Перенос строки `\` в конце команды (частый вид многострочного
      // curl из документации) — просто игнорируем сам символ.
      if (c == '\\' && i + 1 < input.length && (input[i + 1] == '\n' || input[i + 1] == '\r')) {
        continue;
      }
      buffer.write(c);
    }
    if (buffer.isNotEmpty) tokens.add(buffer.toString());
    return tokens;
  }
}
