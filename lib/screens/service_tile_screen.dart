import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/custom_service.dart';
import '../services/ai_service.dart';
import '../services/ai_settings.dart';
import '../services/custom_services_repository.dart';
import '../state/app_data_store.dart';

/// Экран одной плитки сервиса — простую ссылку (без заголовков) сразу
/// открывает во внешнем браузере/приложении и не задерживает на себе
/// (решение пользователя: сервис — это, как правило, целый сайт вроде
/// Google Диска, показывать вместо него что-то своё незачем). Если
/// заданы заголовки или тело запроса (похоже на доступ к API) —
/// выполняет запрос сам и показывает ответ, поскольку заголовки
/// (авторизацию) внешний браузер передать не может.
class ServiceTileScreen extends StatefulWidget {
  final CustomService service;
  final CustomServicesRepository repo;
  const ServiceTileScreen({super.key, required this.service, required this.repo});

  @override
  State<ServiceTileScreen> createState() => _ServiceTileScreenState();
}

class _ServiceTileScreenState extends State<ServiceTileScreen> {
  bool _busy = false;
  bool _aiBusy = false;
  String? _response;
  String? _error;
  bool _showRaw = false;
  late CustomService _service = widget.service;

  /// Если ответ — список записей (Airtable `{"records":[{"fields":{...}}]}`,
  /// обычный `{"items"/"data"/"results":[...]}` или просто массив объектов
  /// верхнего уровня), показываем таблицей вместо сырого JSON — ради
  /// этого и завели универсальные "Сервисы" (решение пользователя: вывести
  /// данные из нужной таблицы в интерфейсе, а не просто текстом ответа).
  List<Map<String, dynamic>>? _rows;

  @override
  void initState() {
    super.initState();
    if (widget.service.isPlainLink) {
      // После кадра — открывать внешнюю ссылку прямо из initState
      // слишком рано (BuildContext ещё не готов для Navigator.pop).
      WidgetsBinding.instance.addPostFrameCallback((_) => _openLink());
    } else {
      _runRequest();
    }
  }

  Future<void> _openLink() async {
    await launchUrl(Uri.parse(widget.service.url), mode: LaunchMode.externalApplication);
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _runRequest() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final s = widget.service;
    try {
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
      setState(() {
        _response = '${res.statusCode}\n\n${_prettyIfJson(text)}';
        _rows = _tryParseRows(text);
      });
    } catch (e) {
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _prettyIfJson(String text) {
    try {
      return const JsonEncoder.withIndent('  ').convert(jsonDecode(text));
    } catch (_) {
      return text;
    }
  }

  /// Airtable кладёт поля записи не на верхний уровень, а в `fields` —
  /// разворачиваем, чтобы колонки таблицы были содержательными (имя
  /// поля из базы), а не одним общим "fields".
  static Map<String, dynamic> _flattenRecord(Map<String, dynamic> r) {
    final fields = r['fields'];
    if (fields is Map) return {if (r['id'] != null) 'id': r['id'], ...fields.map((k, v) => MapEntry('$k', v))};
    return r;
  }

  List<Map<String, dynamic>>? _tryParseRows(String text) {
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
      }
      if (list == null || list.isEmpty || list.any((e) => e is! Map)) return null;
      return list.map((e) => _flattenRecord((e as Map).map((k, v) => MapEntry('$k', v)))).toList();
    } catch (_) {
      return null;
    }
  }

  /// Просит ИИ разложить поля записи по ролям отображения (заголовок,
  /// краткая строка, разворачиваемые подробности) — вместо таблицы,
  /// где длинный текст обрезается и не читается. Показывает ИИ только
  /// НАЗВАНИЯ полей и обрезанные до 60 символов примеры первых двух
  /// записей, а не всю таблицу (решение пользователя: не заваливать
  /// контекст и не гнать в модель приватные данные всех строк). Результат
  /// сохраняется в `custom_services.display_spec` — можно вызвать снова,
  /// чтобы попросить ИИ пересобрать вид, в том числе со своим пожеланием.
  Future<void> _configureDisplay() async {
    final rows = _rows;
    if (rows == null || rows.isEmpty) return;
    final columns = <String>{for (final r in rows) ...r.keys}.toList();

    final noteCtrl = TextEditingController();
    final proceed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Настроить вид с ИИ'),
        content: TextField(
          controller: noteCtrl,
          autofocus: true,
          minLines: 2,
          maxLines: 5,
          decoration: const InputDecoration(
            hintText: 'Необязательно: что показать заголовком, что подробностями и т.п.',
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Отмена')),
          FilledButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('Настроить')),
        ],
      ),
    );
    if (proceed != true || !mounted) return;

    setState(() => _aiBusy = true);
    try {
      final samples = rows.take(2).map((r) => {for (final c in columns) c: _truncate(_cell(r[c]), 60)}).toList();
      final aiSettings = AiSettings(context.read<AppDataStore>().db);
      final reply = await AiService(aiSettings).ask(
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
              if (noteCtrl.text.trim().isNotEmpty) 'пожелание': noteCtrl.text.trim(),
            }),
          ),
        ],
      );
      final decoded = jsonDecode(_stripCodeFence(reply.text));
      if (decoded is! Map) throw const FormatException('Ассистент ответил не JSON-объектом');

      final columnSet = columns.toSet();
      final title = decoded['title'] is String && columnSet.contains(decoded['title']) ? decoded['title'] as String : null;
      List<String> asFieldList(dynamic v) =>
          v is List ? v.map((e) => '$e').where(columnSet.contains).toList() : const [];
      final spec = {
        if (title != null) 'title': title,
        'subtitle': asFieldList(decoded['subtitle']),
        'detail': asFieldList(decoded['detail']),
      };
      final specJson = jsonEncode(spec);
      widget.repo.setDisplaySpec(_service.id, specJson);
      if (!mounted) return;
      setState(() {
        _service = CustomService(
          id: _service.id,
          name: _service.name,
          iconName: _service.iconName,
          url: _service.url,
          method: _service.method,
          headers: _service.headers,
          body: _service.body,
          displaySpec: specJson,
        );
      });
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Не удалось настроить вид: $e')));
    } finally {
      if (mounted) setState(() => _aiBusy = false);
    }
  }

  void _resetDisplay() {
    widget.repo.setDisplaySpec(_service.id, null);
    setState(() {
      _service = CustomService(
        id: _service.id,
        name: _service.name,
        iconName: _service.iconName,
        url: _service.url,
        method: _service.method,
        headers: _service.headers,
        body: _service.body,
      );
    });
  }

  /// На случай, если модель всё же обернула ответ в ```json — снимаем
  /// код-забор, а не отклоняем ответ целиком.
  String _stripCodeFence(String text) {
    final trimmed = text.trim();
    if (!trimmed.startsWith('```')) return trimmed;
    final withoutFirst = trimmed.substring(trimmed.indexOf('\n') + 1);
    final end = withoutFirst.lastIndexOf('```');
    return end == -1 ? withoutFirst.trim() : withoutFirst.substring(0, end).trim();
  }

  static String _truncate(String s, int max) => s.length <= max ? s : '${s.substring(0, max)}…';

  void _showFullCell(String column, String value) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(column),
        content: SingleChildScrollView(child: SelectableText(value)),
        actions: [
          TextButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: value));
              Navigator.of(ctx).pop();
            },
            child: const Text('Копировать'),
          ),
          TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Закрыть')),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.service.isPlainLink) {
      // Пока не сработал postFrameCallback выше — просто крутилка,
      // экран висит на глазах доли секунды.
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    final spec = _parsedSpec();

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.service.name),
        actions: [
          if (_rows != null && !_aiBusy)
            PopupMenuButton<String>(
              icon: const Icon(Icons.auto_awesome_outlined),
              tooltip: 'Вид записей',
              onSelected: (v) {
                if (v == 'configure') _configureDisplay();
                if (v == 'reset') _resetDisplay();
              },
              itemBuilder: (context) => [
                const PopupMenuItem(value: 'configure', child: Text('Настроить вид с ИИ')),
                if (spec != null) const PopupMenuItem(value: 'reset', child: Text('Сбросить вид')),
              ],
            ),
          if (_aiBusy)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: Center(child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))),
            ),
          if (_rows != null)
            IconButton(
              icon: Icon(_showRaw ? Icons.table_chart_outlined : Icons.code),
              tooltip: _showRaw ? 'Показать таблицей' : 'Показать как есть',
              onPressed: () => setState(() => _showRaw = !_showRaw),
            ),
          IconButton(
            icon: const Icon(Icons.open_in_new),
            tooltip: 'Открыть ссылку в браузере',
            onPressed: () => launchUrl(Uri.parse(widget.service.url), mode: LaunchMode.externalApplication),
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _busy ? null : _runRequest,
          ),
        ],
      ),
      body: _busy
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                )
              : (_rows != null && !_showRaw)
                  ? (spec != null ? _buildCards(_rows!, spec) : _buildTable(_rows!))
                  : ListView(
                      padding: const EdgeInsets.all(16),
                      children: [
                        SelectableText(_response ?? '', style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
                      ],
                    ),
      floatingActionButton: _response == null
          ? null
          : FloatingActionButton.small(
              onPressed: () {
                Clipboard.setData(ClipboardData(text: _response!));
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Ответ скопирован')));
              },
              child: const Icon(Icons.copy),
            ),
    );
  }

  Map<String, dynamic>? _parsedSpec() {
    final raw = _service.displaySpec;
    if (raw == null) return null;
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map ? decoded.map((k, v) => MapEntry('$k', v)) : null;
    } catch (_) {
      return null;
    }
  }

  Widget _buildTable(List<Map<String, dynamic>> rows) {
    final columns = <String>{for (final r in rows) ...r.keys}.toList();
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: SingleChildScrollView(
        child: DataTable(
          columns: [for (final c in columns) DataColumn(label: Text(c))],
          rows: [
            for (final r in rows)
              DataRow(cells: [
                for (final c in columns)
                  DataCell(
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 220),
                      child: Text(_cell(r[c]), overflow: TextOverflow.ellipsis, maxLines: 2),
                    ),
                    // Ячейка режется по ширине колонки — полный текст (не
                    // помещающаяся заметка и т.п.) смотрим по тапу в диалоге,
                    // а не растягиваем таблицу под самое длинное значение.
                    onTap: () => _showFullCell(c, _cell(r[c])),
                  ),
              ]),
          ],
        ),
      ),
    );
  }

  /// Вид по разметке ИИ — заголовок и краткая строка сразу видны,
  /// длинные поля (заметки, описания) читаются полностью в развороте
  /// карточки вместо обрезанной ячейки таблицы.
  Widget _buildCards(List<Map<String, dynamic>> rows, Map<String, dynamic> spec) {
    final title = spec['title'] as String?;
    final subtitle = (spec['subtitle'] as List?)?.map((e) => '$e').toList() ?? const [];
    final detail = (spec['detail'] as List?)?.map((e) => '$e').toList() ?? const [];
    return ListView.builder(
      padding: const EdgeInsets.all(12),
      itemCount: rows.length,
      itemBuilder: (context, i) {
        final r = rows[i];
        final titleText = title != null ? _cell(r[title]) : (r.values.isEmpty ? '' : _cell(r.values.first));
        final subtitleText = subtitle.map((k) => _cell(r[k])).where((v) => v.isNotEmpty).join(' · ');
        final detailEntries = [
          for (final k in detail)
            if (_cell(r[k]).isNotEmpty) MapEntry(k, _cell(r[k])),
        ];
        return Card(
          margin: const EdgeInsets.only(bottom: 8),
          child: ExpansionTile(
            title: Text(titleText.isEmpty ? '—' : titleText, style: const TextStyle(fontWeight: FontWeight.w600)),
            subtitle: subtitleText.isEmpty ? null : Text(subtitleText),
            children: [
              for (final e in detailEntries)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(e.key, style: Theme.of(context).textTheme.labelSmall),
                      SelectableText(e.value),
                    ],
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  static String _cell(dynamic v) {
    if (v == null) return '';
    if (v is List || v is Map) return jsonEncode(v);
    return '$v';
  }
}
