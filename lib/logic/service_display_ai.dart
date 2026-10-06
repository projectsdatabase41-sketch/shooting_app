import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/custom_service.dart';
import '../services/ai_service.dart';
import '../services/ai_settings.dart';

/// Общая часть "запросить сервис → распознать записи → попросить ИИ
/// разложить поля по ролям отображения (заголовок/кратко/подробно)" —
/// используется и сразу при создании/изменении сервиса (решение
/// пользователя: маска должна появляться сама, без отдельного похода в
/// плитку), и вручную с экрана плитки ("Настроить вид с ИИ" — пересобрать
/// или уточнить пожеланием).
class ServiceDisplayAi {
  /// Выполняет запрос сервиса. Возвращает читаемый текст ответа (код +
  /// JSON с отступами, если это JSON), сырой текст тела ответа (для
  /// [discoverAndSuggestSpec], если обычная эвристика не распознает
  /// список) и разобранные записи, если ответ — список (или один
  /// объект-запись).
  static Future<
          (String response, String rawText, List<Map<String, dynamic>>? rows)>
      fetchRows(CustomService s) async {
    final uri = Uri.parse(s.url);
    final http.Response res;
    switch (s.method) {
      case 'POST':
        res = await http.post(uri, headers: s.headers, body: s.body);
      case 'PUT':
        res = await http.put(uri, headers: s.headers, body: s.body);
      case 'DELETE':
        res = await http.delete(uri, headers: s.headers, body: s.body);
      default:
        res = await http.get(uri, headers: s.headers);
    }
    final text = utf8.decode(res.bodyBytes);
    return (
      '${res.statusCode}\n\n${_prettyIfJson(text)}',
      text,
      _tryParseRows(text)
    );
  }

  static String _prettyIfJson(String text) {
    try {
      return const JsonEncoder.withIndent('  ').convert(jsonDecode(text));
    } catch (_) {
      return text;
    }
  }

  /// Airtable кладёт поля записи не на верхний уровень, а в `fields` —
  /// разворачиваем, чтобы колонки были содержательными (имя поля из базы),
  /// а не одним общим "fields".
  static Map<String, dynamic> _flattenRecord(Map<String, dynamic> r) {
    final fields = r['fields'];
    if (fields is Map)
      return {
        if (r['id'] != null) 'id': r['id'],
        ...fields.map((k, v) => MapEntry('$k', v))
      };
    return r;
  }

  static List<Map<String, dynamic>>? _tryParseRows(String text) {
    try {
      final decoded = jsonDecode(text);
      List? list;
      if (decoded is List) {
        list = decoded;
      } else if (decoded is Map) {
        for (final key in ['records', 'items', 'data', 'results', 'rows']) {
          final v = decoded[key];
          if (v is List) {
            list = v;
            break;
          }
        }
        // Ни одного из известных ключей списка нет — сам ответ, похоже,
        // и есть одна запись (например, "получить одну строку" в REST
        // или объект вида {"id":..,"fields":{...}} у Airtable).
        list ??= decoded.isEmpty ? null : [decoded];
      }
      if (list == null || list.isEmpty || list.any((e) => e is! Map))
        return null;
      return list
          .map((e) =>
              _flattenRecord((e as Map).map((k, v) => MapEntry('$k', v))))
          .toList();
    } catch (_) {
      return null;
    }
  }

  /// Просит ИИ разложить поля записи по ролям отображения. Показывает ей
  /// только НАЗВАНИЯ полей и обрезанные до 60 символов примеры первых
  /// двух записей — не всю таблицу (решение пользователя: не заваливать
  /// контекст и не гнать в модель приватные данные всех строк). Бросает
  /// исключение при неудаче (нет ключа, модель ответила не JSON и т.п.) —
  /// вызывающий код сам решает, показывать это пользователю или считать
  /// необязательным шагом и просто оставить обычную таблицу.
  static Future<String> suggestSpec(
    AiSettings settings,
    List<Map<String, dynamic>> rows, {
    String note = '',
  }) async {
    final columns = <String>{for (final r in rows) ...r.keys}.toList();
    final samples = rows
        .take(2)
        .map((r) => {for (final c in columns) c: truncate(cell(r[c]), 60)})
        .toList();
    final reply = await AiService(settings).ask(
      task: 'service_display',
      json: true,
      systemPrompt:
          'You assign the fields of a third-party API record to display roles in a list card. '
          'You get only the list of field names and a couple of truncated example values — not the whole table. '
          'Answer with a JSON object ONLY, no explanations, no markdown, no ```: '
          '{"title": "one field for the card title", '
          '"subtitle": ["1-3 fields for a short line under the title"], '
          '"detail": ["the other meaningful fields — shown in full when the card is expanded"]}. '
          'Take the field names STRICTLY from the "fields" list — do not invent new ones. '
          'The field with the longest text (description, note, comment) always goes to detail, not to title/subtitle.',
      contextBlock: '',
      history: [
        (
          role: 'user',
          text: jsonEncode({
            'fields': columns,
            'examples': samples,
            if (note.trim().isNotEmpty) 'note': note.trim(),
          }),
        ),
      ],
    );
    final decoded = jsonDecode(_stripCodeFence(reply.text));
    if (decoded is! Map)
      throw const FormatException('Ассистент ответил не JSON-объектом');

    final columnSet = columns.toSet();
    final title =
        decoded['title'] is String && columnSet.contains(decoded['title'])
            ? decoded['title'] as String
            : null;
    List<String> asFieldList(dynamic v) => v is List
        ? v.map((e) => '$e').where(columnSet.contains).toList()
        : const [];
    final spec = {
      if (title != null) 'title': title,
      'subtitle': asFieldList(decoded['subtitle']),
      'detail': asFieldList(decoded['detail']),
    };
    return jsonEncode(spec);
  }

  /// Идёт по точечному пути ("data.items") внутри разобранного JSON и
  /// возвращает найденный список записей — пусто/не указано означает,
  /// что сам корень и есть одна запись.
  static List<Map<String, dynamic>>? _applyListPath(
      dynamic root, String listPath) {
    var node = root;
    if (listPath.trim().isNotEmpty) {
      for (final segment in listPath.split('.')) {
        if (node is Map && node.containsKey(segment)) {
          node = node[segment];
        } else {
          return null;
        }
      }
    }
    List? list;
    if (node is List) {
      list = node;
    } else if (node is Map && node.isNotEmpty) {
      list = [node];
    }
    if (list == null || list.isEmpty || list.any((e) => e is! Map)) return null;
    return list
        .map((e) => _flattenRecord((e as Map).map((k, v) => MapEntry('$k', v))))
        .toList();
  }

  /// Когда обычная эвристика (`fetchRows`) не нашла список записей —
  /// ответ нестандартной формы — просит ИИ одновременно найти путь к
  /// списку И разложить поля по ролям, по обрезанному образцу самого
  /// ответа (не целиком, чтобы не заваливать контекст). Бросает
  /// исключение, если модель не смогла найти в ответе ничего похожего
  /// на список записей.
  static Future<(List<Map<String, dynamic>> rows, String specJson)>
      discoverAndSuggestSpec(
    AiSettings settings,
    String rawResponseText, {
    String note = '',
  }) async {
    final dynamic root;
    try {
      root = jsonDecode(rawResponseText);
    } catch (_) {
      // Не JSON вовсе (XML, CSV, произвольный текст) — отдельный путь,
      // без парсера под каждый формат (решение пользователя, пункты 18/19).
      return _discoverFromNonJson(settings, rawResponseText, note: note);
    }
    final preview = truncate(const JsonEncoder().convert(root), 3000);
    final reply = await AiService(settings).ask(
      task: 'service_discover',
      json: true,
      systemPrompt:
          'You get a truncated sample of a third-party API response (JSON) in which the usual heuristic did not '
          'find a list of records under the standard keys (records/items/data/results/rows). '
          'Find the path to the list of records yourself and assign the fields to display roles in a list card. '
          'Answer with a JSON object ONLY, no explanations, no markdown, no ```: '
          '{"listPath": "dot-separated path to the array of records inside the response, e.g. data.items or result.rows; '
          'empty if the response root is already the list or a single record", '
          '"title": "field for the card title", '
          '"subtitle": ["1-3 fields for a short line under the title"], '
          '"detail": ["the other meaningful fields — shown in full when the card is expanded"]}. '
          'Take the path and field names STRICTLY from the given JSON, do not invent them.',
      contextBlock: '',
      history: [
        (
          role: 'user',
          text: jsonEncode({
            'response_preview': preview,
            if (note.trim().isNotEmpty) 'note': note.trim(),
          }),
        ),
      ],
    );
    final decoded = jsonDecode(_stripCodeFence(reply.text));
    if (decoded is! Map)
      throw const FormatException('Ассистент ответил не JSON-объектом');

    final rows = _applyListPath(root, '${decoded['listPath'] ?? ''}');
    if (rows == null || rows.isEmpty) {
      throw const FormatException(
          'Не нашлось список записей в ответе — проверьте адрес сервиса');
    }
    final columnSet = <String>{for (final r in rows) ...r.keys};
    final title =
        decoded['title'] is String && columnSet.contains(decoded['title'])
            ? decoded['title'] as String
            : null;
    List<String> asFieldList(dynamic v) => v is List
        ? v.map((e) => '$e').where(columnSet.contains).toList()
        : const [];
    final spec = {
      if (title != null) 'title': title,
      'subtitle': asFieldList(decoded['subtitle']),
      'detail': asFieldList(decoded['detail']),
    };
    return (rows, jsonEncode(spec));
  }

  /// Ответ сервиса не в JSON (XML, CSV, произвольный текст, таблица) —
  /// вместо парсера под каждый формат по отдельности просим сам ИИ
  /// вытащить записи прямо из текста и сразу разложить поля по ролям
  /// (решение пользователя, пункты 18/19: "любой другой формат", не
  /// только JSON с нестандартными ключами списка).
  static Future<(List<Map<String, dynamic>> rows, String specJson)>
      _discoverFromNonJson(
    AiSettings settings,
    String rawResponseText, {
    String note = '',
  }) async {
    final preview = truncate(rawResponseText, 4000);
    final reply = await AiService(settings).ask(
      task: 'service_discover_text',
      json: true,
      systemPrompt:
          'You get a truncated third-party API response that is NOT JSON (it may be XML, CSV, '
          'free text, a table — anything). Extract the records (table rows) from it and assign the fields '
          'to display roles in a list card. Answer with a JSON object ONLY, no explanations, no markdown, '
          'no ```: {"rows": [{"field": "value", …}, …], "title": "field for the card title", '
          '"subtitle": ["1-3 fields for a short line under the title"], '
          '"detail": ["the other meaningful fields — shown in full when the card is expanded"]}. '
          'Invent the field names yourself from the meaning of the content (XML attributes, CSV headers, labels in the text). '
          'If there are several records, return all of them, not only the first. Keep values in the original language.',
      contextBlock: '',
      history: [
        (
          role: 'user',
          text: jsonEncode({
            'response_preview': preview,
            if (note.trim().isNotEmpty) 'note': note.trim()
          }),
        ),
      ],
    );
    final decoded = jsonDecode(_stripCodeFence(reply.text));
    if (decoded is! Map)
      throw const FormatException('Ассистент ответил не JSON-объектом');
    final rawRows = decoded['rows'];
    if (rawRows is! List || rawRows.isEmpty || rawRows.any((e) => e is! Map)) {
      throw const FormatException(
          'Не удалось извлечь записи из ответа сервиса');
    }
    final rows = rawRows
        .map((e) => (e as Map).map((k, v) => MapEntry('$k', v)))
        .toList();
    final columnSet = <String>{for (final r in rows) ...r.keys};
    final title =
        decoded['title'] is String && columnSet.contains(decoded['title'])
            ? decoded['title'] as String
            : null;
    List<String> asFieldList(dynamic v) => v is List
        ? v.map((e) => '$e').where(columnSet.contains).toList()
        : const [];
    final spec = {
      if (title != null) 'title': title,
      'subtitle': asFieldList(decoded['subtitle']),
      'detail': asFieldList(decoded['detail']),
    };
    return (rows, jsonEncode(spec));
  }

  /// "Второй уровень" ИИ (решение пользователя) — не меняет вид записей
  /// (это делает [suggestSpec]/[discoverAndSuggestSpec]), а отбирает
  /// нужные по свободному запросу вроде "покажи все про долги". Модели
  /// НЕ даём сами записи — только названия полей и уникальные значения
  /// по каждому (обрезанный "словарь" значений, не содержимое таблицы:
  /// на большой таблице это быстро провалит контекст и раскрыло бы ИИ
  /// личные данные, которых просить не нужно). Она выбирает ОДНО поле и
  /// подходящие значения СТРОГО из данного набора; сам отбор строк —
  /// точное сравнение в Dart-коде ниже, ИИ никогда не видит и не
  /// пересказывает содержимое конкретных записей.
  static Future<({String field, List<String> values, String reply})>
      suggestFilter(
    AiSettings settings,
    List<Map<String, dynamic>> rows,
    String query,
  ) async {
    final columns = <String>{for (final r in rows) ...r.keys}.toList();
    final valuesByField = <String, List<String>>{};
    for (final c in columns) {
      final values = <String>{};
      for (final r in rows) {
        final v = cell(r[c]).trim();
        if (v.isNotEmpty) values.add(truncate(v, 60));
        if (values.length >= 40) break;
      }
      if (values.isNotEmpty) valuesByField[c] = values.toList();
    }
    final reply = await AiService(settings).ask(
      task: 'service_filter',
      json: true,
      systemPrompt:
          'You help select the needed records from a third-party service table by the free-form request of '
          'the user. You are NOT given the table itself — only the list of fields and the unique values of each '
          '(they may be truncated). Choose EXACTLY ONE field for the filter and the matching values STRICTLY from the given '
          'set (do not invent new ones, do not correct them). Answer with a JSON object ONLY, no explanations, no '
          'markdown, no ```: {"field": "field name from the list, or empty", '
          '"values": ["matching values strictly from the set"], '
          '"reply": "a short answer to the user about what will be shown, 1 sentence, in the language of the request"}. '
          'If the request is not about selecting by a specific field (a general question, not a filter) — "field" and "values" are empty.',
      contextBlock: '',
      history: [
        (
          role: 'user',
          text: jsonEncode({
            'fields': columns,
            'values_by_field': valuesByField,
            'query': query
          })
        ),
      ],
    );
    final decoded = jsonDecode(_stripCodeFence(reply.text));
    if (decoded is! Map)
      throw const FormatException('Ассистент ответил не JSON-объектом');
    final field =
        decoded['field'] is String && columns.contains(decoded['field'])
            ? decoded['field'] as String
            : '';
    final values = decoded['values'] is List
        ? (decoded['values'] as List).map((e) => '$e').toList()
        : <String>[];
    final replyText =
        decoded['reply'] is String ? decoded['reply'] as String : '';
    return (field: field, values: values, reply: replyText);
  }

  /// Применяет фильтр из [suggestFilter] к записям — сравнение без учёта
  /// регистра, по вхождению (значение из набора могло быть обрезано на
  /// 60 символах, поэтому не строгое равенство).
  static List<Map<String, dynamic>> applyFilter(
    List<Map<String, dynamic>> rows,
    String field,
    List<String> values,
  ) {
    if (field.isEmpty || values.isEmpty) return rows;
    final needles = values
        .map((v) => v.replaceAll('…', '').trim().toLowerCase())
        .where((v) => v.isNotEmpty)
        .toList();
    if (needles.isEmpty) return rows;
    return rows.where((r) {
      final v = cell(r[field]).toLowerCase();
      return needles.any((n) => v.contains(n) || n.contains(v));
    }).toList();
  }

  /// На случай, если модель всё же обернула ответ в ```json — снимаем
  /// код-забор, а не отклоняем ответ целиком.
  static String _stripCodeFence(String text) {
    final trimmed = text.trim();
    if (!trimmed.startsWith('```')) return trimmed;
    final withoutFirst = trimmed.substring(trimmed.indexOf('\n') + 1);
    final end = withoutFirst.lastIndexOf('```');
    return end == -1
        ? withoutFirst.trim()
        : withoutFirst.substring(0, end).trim();
  }

  static String truncate(String s, int max) =>
      s.length <= max ? s : '${s.substring(0, max)}…';

  static String cell(dynamic v) {
    if (v == null) return '';
    if (v is List || v is Map) return jsonEncode(v);
    return '$v';
  }
}
