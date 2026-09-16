import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../logic/service_display_ai.dart';
import '../models/custom_service.dart';
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
  /// обычный `{"items"/"data"/"results":[...]}`, один объект-запись или
  /// просто массив объектов верхнего уровня), показываем таблицей вместо
  /// сырого JSON — ради этого и завели универсальные "Сервисы" (решение
  /// пользователя: вывести данные из нужной таблицы, а не текстом ответа).
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
    try {
      final (response, rows) = await ServiceDisplayAi.fetchRows(widget.service);
      setState(() {
        _response = response;
        _rows = rows;
      });
    } catch (e) {
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Ручной вызов с экрана плитки — в отличие от автоматического подбора
  /// сразу при сохранении сервиса (см. `AddServiceScreen._save`), тут
  /// можно ещё и уточнить пожеланием, и вызвать повторно.
  Future<void> _configureDisplay() async {
    final rows = _rows;
    if (rows == null || rows.isEmpty) return;

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
      final aiSettings = AiSettings(context.read<AppDataStore>().db);
      final specJson = await ServiceDisplayAi.suggestSpec(aiSettings, rows, note: noteCtrl.text);
      widget.repo.setDisplaySpec(_service.id, specJson);
      if (!mounted) return;
      setState(() => _service = _withDisplaySpec(specJson));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Не удалось настроить вид: $e')));
    } finally {
      if (mounted) setState(() => _aiBusy = false);
    }
  }

  void _resetDisplay() {
    widget.repo.setDisplaySpec(_service.id, null);
    setState(() => _service = _withDisplaySpec(null));
  }

  CustomService _withDisplaySpec(String? displaySpec) => CustomService(
        id: _service.id,
        name: _service.name,
        iconName: _service.iconName,
        url: _service.url,
        method: _service.method,
        headers: _service.headers,
        body: _service.body,
        displaySpec: displaySpec,
      );

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
                      child: Text(ServiceDisplayAi.cell(r[c]), overflow: TextOverflow.ellipsis, maxLines: 2),
                    ),
                    // Ячейка режется по ширине колонки — полный текст (не
                    // помещающаяся заметка и т.п.) смотрим по тапу в диалоге,
                    // а не растягиваем таблицу под самое длинное значение.
                    onTap: () => _showFullCell(c, ServiceDisplayAi.cell(r[c])),
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
        final titleText =
            title != null ? ServiceDisplayAi.cell(r[title]) : (r.values.isEmpty ? '' : ServiceDisplayAi.cell(r.values.first));
        final subtitleText =
            subtitle.map((k) => ServiceDisplayAi.cell(r[k])).where((v) => v.isNotEmpty).join(' · ');
        final detailEntries = [
          for (final k in detail)
            if (ServiceDisplayAi.cell(r[k]).isNotEmpty) MapEntry(k, ServiceDisplayAi.cell(r[k])),
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
}
