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
  /// JSON с отступами, если это JSON) и разобранные записи, если ответ —
  /// список (или один объект-запись).
  static Future<(String response, List<Map<String, dynamic>>? rows)> fetchRows(CustomService s) async {
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
    return ('${res.statusCode}\n\n${_prettyIfJson(text)}', _tryParseRows(text));
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
    if (fields is Map) return {if (r['id'] != null) 'id': r['id'], ...fields.map((k, v) => MapEntry('$k', v))};
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
      if (list == null || list.isEmpty || list.any((e) => e is! Map)) return null;
      return list.map((e) => _flattenRecord((e as Map).map((k, v) => MapEntry('$k', v)))).toList();
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
    final samples = rows.take(2).map((r) => {for (final c in columns) c: truncate(cell(r[c]), 60)}).toList();
    final reply = await AiService(settings).ask(
      systemPrompt: 'Ты раскладываешь поля записей стороннего API по ролям отображения в карточке списка. '
          'Тебе дан только список названий полей и по паре обрезанных примеров значений — не вся таблица. '
          'Ответь ТОЛЬКО JSON-объектом без пояснений, без markdown, без ```: '
          '{"title": "одно поле для заголовка карточки", '
          '"subtitle": ["1-3 поля для краткой строки под заголовком"], '
          '"detail": ["остальные значимые поля — показываются полностью в развороте карточки"]}. '
          'Названия полей бери СТРОГО из списка "fields" — не придумывай новых. '
          'Поле с самым длинным текстом (описание, заметка, комментарий) — всегда в detail, не в title/subtitle.',
      contextBlock: '',
      history: [
        (
          role: 'user',
          text: jsonEncode({
            'fields': columns,
            'examples': samples,
            if (note.trim().isNotEmpty) 'пожелание': note.trim(),
          }),
        ),
      ],
    );
    final decoded = jsonDecode(_stripCodeFence(reply.text));
    if (decoded is! Map) throw const FormatException('Ассистент ответил не JSON-объектом');

    final columnSet = columns.toSet();
    final title = decoded['title'] is String && columnSet.contains(decoded['title']) ? decoded['title'] as String : null;
    List<String> asFieldList(dynamic v) => v is List ? v.map((e) => '$e').where(columnSet.contains).toList() : const [];
    final spec = {
      if (title != null) 'title': title,
      'subtitle': asFieldList(decoded['subtitle']),
      'detail': asFieldList(decoded['detail']),
    };
    return jsonEncode(spec);
  }

  /// На случай, если модель всё же обернула ответ в ```json — снимаем
  /// код-забор, а не отклоняем ответ целиком.
  static String _stripCodeFence(String text) {
    final trimmed = text.trim();
    if (!trimmed.startsWith('```')) return trimmed;
    final withoutFirst = trimmed.substring(trimmed.indexOf('\n') + 1);
    final end = withoutFirst.lastIndexOf('```');
    return end == -1 ? withoutFirst.trim() : withoutFirst.substring(0, end).trim();
  }

  static String truncate(String s, int max) => s.length <= max ? s : '${s.substring(0, max)}…';

  static String cell(dynamic v) {
    if (v == null) return '';
    if (v is List || v is Map) return jsonEncode(v);
    return '$v';
  }
}
