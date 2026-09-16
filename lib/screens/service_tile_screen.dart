import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

import '../models/custom_service.dart';

/// Экран одной плитки сервиса — простую ссылку (без заголовков) сразу
/// открывает во внешнем браузере/приложении и не задерживает на себе
/// (решение пользователя: сервис — это, как правило, целый сайт вроде
/// Google Диска, показывать вместо него что-то своё незачем). Если
/// заданы заголовки или тело запроса (похоже на доступ к API) —
/// выполняет запрос сам и показывает ответ, поскольку заголовки
/// (авторизацию) внешний браузер передать не может.
class ServiceTileScreen extends StatefulWidget {
  final CustomService service;
  const ServiceTileScreen({super.key, required this.service});

  @override
  State<ServiceTileScreen> createState() => _ServiceTileScreenState();
}

class _ServiceTileScreenState extends State<ServiceTileScreen> {
  bool _busy = false;
  String? _response;
  String? _error;
  bool _showRaw = false;

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

  @override
  Widget build(BuildContext context) {
    if (widget.service.isPlainLink) {
      // Пока не сработал postFrameCallback выше — просто крутилка,
      // экран висит на глазах доли секунды.
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.service.name),
        actions: [
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
                  ? _buildTable(_rows!)
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
                for (final c in columns) DataCell(Text(_cell(r[c]))),
              ]),
          ],
        ),
      ),
    );
  }

  static String _cell(dynamic v) {
    if (v == null) return '';
    if (v is List || v is Map) return jsonEncode(v);
    return '$v';
  }
}
