import '../services/app_lock.dart';
import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../i18n/i18n.dart';
import '../import/scatt_pdf.dart';
import '../i18n/known_names.dart';
import '../logic/friendly_error.dart';
import '../models/target_face.dart';
import '../services/session_import.dart';
import '../state/app_data_store.dart';
import '../state/personalization_view_model.dart';
import '../painters/target_painter.dart';
import '../widgets/glass_pill.dart';
import '../widgets/section_header.dart';

enum _Status { clean, problems, duplicate }

class _Item {
  final String file;
  final ImportedSession session;
  final String? key; // ключ повторного импорта (если файл его даёт)
  final List<String> problems;
  _Status status;
  bool selected;
  bool written = false;
  _Item(this.file, this.session, this.key, this.problems, this.status) : selected = status == _Status.clean;
}

/// Импорт тренировок из файлов: выберите один или сразу много (PDF и JSON). Приложение само находит
/// среди них тренировки и разбирает; всё остальное молча пропускает. Ничего не пишется, пока вы
/// не нажмёте «Записать»: сначала список (и просмотр каждой тренировки), потом запись пачкой.
class ImportScreen extends StatefulWidget {
  const ImportScreen({super.key});

  @override
  State<ImportScreen> createState() => _ImportScreenState();
}

class _ImportScreenState extends State<ImportScreen> {
  final _items = <_Item>[];
  final _skipped = <String>[]; // имена файлов, не распознанных как тренировки
  int _total = 0, _done = 0;
  bool _busy = false;
  String? _error;
  int? _applied;

  static const _maxFiles = 500;

  Future<void> _pick() async {
    setState(() {
      _error = null;
      _applied = null;
    });
    FilePickerResult? result;
    try {
      result = await AppLock.external(() => FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['pdf', 'json'],
        allowMultiple: true,
        // Байты просим всегда (в вебе файла на диске нет, dart:io туда не компилируется).
        withData: true,
      ));
    } catch (e) {
      setState(() => _error = friendlyError(e));
      return;
    }
    if (result == null || result.files.isEmpty) return;
    final files = result.files.take(_maxFiles).toList();
    setState(() {
      _busy = true;
      _items.clear();
      _skipped.clear();
      _total = files.length;
      _done = 0;
    });
    final store = context.read<AppDataStore>();
    final seen = <String>{};
    for (final f in files) {
      if (!mounted) return;
      final bytes = f.bytes;
      if (bytes != null && bytes.isNotEmpty) {
        try {
          await _handle(store, f.name, bytes, seen);
        } catch (_) {
          _skipped.add(f.name);
        }
      } else {
        _skipped.add(f.name);
      }
      if (mounted) setState(() => _done++);
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _handle(AppDataStore store, String name, Uint8List bytes, Set<String> seen) async {
    final lower = name.toLowerCase();
    if (lower.endsWith('.json')) {
      try {
        final bundle = SessionImport.parse(utf8.decode(bytes));
        for (final s in bundle.sessions) {
          _add(store, name, s, null, const [], seen);
        }
      } catch (_) {
        _skipped.add(name);
      }
      return;
    }
    // PDF: разбор тяжёлый — в отдельном изоляте; чужой файл просто «не распознан».
    final r = await compute(scattTryParse, bytes);
    if (r['ok'] != true) {
      _skipped.add(name);
      return;
    }
    final bundle = SessionImport.parse(jsonEncode({
      'format': SessionImport.formatId,
      'version': SessionImport.supportedVersion,
      'source': 'SCATT (PDF)',
      'sessions': [r['session']],
    }));
    _add(store, name, bundle.sessions.first, r['key'] as String?, [for (final p in r['problems'] as List) '$p'], seen);
  }

  void _add(AppDataStore store, String file, ImportedSession s, String? key, List<String> problems, Set<String> seen) {
    final dupInBatch = key != null && !seen.add(key);
    if (dupInBatch) return; // один и тот же отчёт выбран дважды — берём один
    final status = SessionImport.alreadyHave(store, s)
        ? _Status.duplicate
        : (problems.isEmpty ? _Status.clean : _Status.problems);
    _items.add(_Item(file, s, key, problems, status));
  }

  int get _selectedCount => _items.where((i) => i.selected && !i.written).length;

  void _applySelected() {
    final store = context.read<AppDataStore>();
    var n = 0;
    for (final i in _items.where((i) => i.selected && !i.written)) {
      n += SessionImport.apply(store, ImportBundle(source: i.session.session.extra?['импортировано_из']?.toString() ?? 'файл', sessions: [i.session]));
      i.written = true;
      i.status = _Status.duplicate;
      i.selected = false;
    }
    setState(() => _applied = (_applied ?? 0) + n);
  }

  Future<void> _preview(_Item item) async {
    final write = await Navigator.of(context).push<bool>(MaterialPageRoute(builder: (_) => _PreviewScreen(item: item)));
    if (write == true && mounted && !item.written) {
      item.selected = true;
      _applySelected();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final df = DateFormat('dd.MM.yyyy HH:mm');
    final topInset = MediaQuery.paddingOf(context).top;
    final clean = _items.where((i) => i.status == _Status.clean).length;
    final dup = _items.where((i) => i.status == _Status.duplicate).length;
    final probs = _items.where((i) => i.status == _Status.problems).length;
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: GlassHeader(title: Text(tr('Импорт тренировок'), style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600))),
      bottomNavigationBar: _items.isEmpty || _busy
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: FilledButton.icon(
                  onPressed: _selectedCount == 0 ? null : _applySelected,
                  icon: const Icon(Icons.save_alt),
                  label: Text(tr('Записать выбранные ({n})', {'n': _selectedCount})),
                ),
              ),
            ),
      body: ListView(
        padding: EdgeInsets.fromLTRB(16, topInset + GlassHeader.height + 8, 16, 24),
        children: [
          SectionHeader(
            title: tr('Файлы'),
            subtitle: tr('Выберите файлы с тренировками (PDF или JSON) — можно сразу много. Нужные тренировки приложение найдёт само, остальные файлы пропустит. Записывается только после подтверждения.'),
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: _busy ? null : _pick,
            icon: _busy ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.folder_open),
            label: Text(_busy ? tr('Разбор: {a} из {b}', {'a': _done, 'b': _total}) : tr('Выбрать файлы')),
          ),
          if (_busy && _total > 0) ...[
            const SizedBox(height: 8),
            LinearProgressIndicator(value: _done / _total),
          ],
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!, style: TextStyle(color: cs.error)),
          ],
          Builder(builder: (context) {
            final store = context.watch<AppDataStore>();
            final merges = SessionImport.plannedMerges(store, scattExerciseNames.toSet());
            if (merges.isEmpty) return const SizedBox.shrink();
            return Card(
              margin: const EdgeInsets.only(top: 12),
              child: ListTile(
                leading: const Icon(Icons.merge_type),
                title: Text(tr('Лишние упражнения от импорта: {n}', {'n': merges.length})),
                subtitle: Text(tr('Тренировки будут перенесены в ваши упражнения на той же мишени, лишние удалены')),
                trailing: FilledButton(
                  onPressed: () {
                    final n = SessionImport.applyMerges(store, merges);
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('Объединено упражнений: {n}', {'n': n}))));
                  },
                  child: Text(tr('Объединить')),
                ),
              ),
            );
          }),
          if (_applied != null) ...[
            const SizedBox(height: 12),
            Card(
              child: ListTile(
                leading: Icon(Icons.check_circle, color: cs.primary),
                title: Text(tr('Записано тренировок: {n}', {'n': _applied})),
              ),
            ),
          ],
          if (!_busy && (_items.isNotEmpty || _skipped.isNotEmpty)) ...[
            const SizedBox(height: 16),
            Text(
              tr('Найдено тренировок: {n}', {'n': _items.length}) +
                  (dup > 0 ? ' · ${tr('уже есть: {n}', {'n': dup})}' : '') +
                  (probs > 0 ? ' · ${tr('с замечаниями: {n}', {'n': probs})}' : '') +
                  (clean > 0 ? ' · ${tr('готово к записи: {n}', {'n': clean})}' : ''),
              style: theme.textTheme.bodyMedium,
            ),
            if (_skipped.isNotEmpty)
              Theme(
                data: theme.copyWith(dividerColor: Colors.transparent),
                child: ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  title: Text(tr('Пропущено файлов: {n}', {'n': _skipped.length}), style: theme.textTheme.bodySmall),
                  children: [for (final f in _skipped.take(200)) Align(alignment: Alignment.centerLeft, child: Text(f, style: theme.textTheme.bodySmall))],
                ),
              ),
            const SizedBox(height: 8),
            for (final i in _items)
              Card(
                margin: const EdgeInsets.only(bottom: 8),
                child: ListTile(
                  onTap: () => _preview(i),
                  leading: Checkbox(
                    value: i.selected,
                    onChanged: i.status == _Status.duplicate ? null : (v) => setState(() => i.selected = v ?? false),
                  ),
                  title: Text('${df.format(i.session.session.startedAt!)} · ${tr(i.session.exerciseName)}'),
                  subtitle: Text(
                    [
                      tr('{n} выстр.', {'n': i.session.session.shots.length}),
                      tr('сумма {s}', {'s': i.session.session.totalScore.toStringAsFixed(1)}),
                      if (i.status == _Status.duplicate) i.written ? tr('записано') : tr('уже есть в базе'),
                      if (i.status == _Status.problems) '${tr('замечания')}: ${i.problems.first}',
                    ].join(' · '),
                    style: i.status == _Status.problems ? TextStyle(color: cs.error) : null,
                  ),
                  trailing: const Icon(Icons.visibility_outlined),
                ),
              ),
          ],
        ],
      ),
    );
  }
}

/// Просмотр одной тренировки до записи: мишень с пробоинами по сериям, таблица серий, замечания.
class _PreviewScreen extends StatelessWidget {
  final _Item item;
  const _PreviewScreen({required this.item});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final s = item.session.session;
    final face = TargetFace.byCode(item.session.targetFaceCode);
    final scheme = context.read<PersonalizationViewModel>().scheme;
    final df = DateFormat('dd.MM.yyyy HH:mm');
    final bySeries = <int, List<double>>{};
    for (final sh in s.shots) {
      bySeries.putIfAbsent(sh.seriesNo, () => []).add(sh.score);
    }
    final topInset = MediaQuery.paddingOf(context).top;
    final canWrite = item.status == _Status.clean && !item.written;
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: GlassHeader(title: Text(tr(item.session.exerciseName), style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600))),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(children: [
            Expanded(child: OutlinedButton(onPressed: () => Navigator.of(context).pop(false), child: Text(tr('Назад')))),
            const SizedBox(width: 12),
            Expanded(
              child: FilledButton(
                onPressed: canWrite ? () => Navigator.of(context).pop(true) : null,
                child: Text(item.written || item.status == _Status.duplicate ? tr('Уже в базе') : tr('Записать')),
              ),
            ),
          ]),
        ),
      ),
      body: ListView(
        padding: EdgeInsets.fromLTRB(16, topInset + GlassHeader.height + 8, 16, 24),
        children: [
          Text('${df.format(s.startedAt!)} · ${tr('{n} выстр.', {'n': s.shots.length})} · ${tr('сумма {s}', {'s': s.totalScore.toStringAsFixed(1)})}', style: theme.textTheme.bodyMedium),
          const SizedBox(height: 12),
          AspectRatio(
            aspectRatio: 1,
            child: CustomPaint(
              painter: TargetPainter(
                face: face,
                colors: scheme,
                visibleShots: s.shots,
                selectedShot: null,
                currentSeriesNo: s.shots.isEmpty ? 1 : s.shots.last.seriesNo,
              ),
            ),
          ),
          const SizedBox(height: 12),
          if (item.problems.isNotEmpty) ...[
            for (final p in item.problems) Text('• $p', style: TextStyle(color: cs.error)),
            const SizedBox(height: 4),
            Text(tr('С замечаниями тренировка не записывается: данные могли разобраться неверно.'), style: theme.textTheme.bodySmall),
            const SizedBox(height: 12),
          ],
          for (final e in bySeries.entries)
            ListTile(
              dense: true,
              title: Text(tr('Серия {n}', {'n': e.key})),
              trailing: Text(e.value.fold<double>(0, (a, b) => a + b).toStringAsFixed(1), style: theme.textTheme.titleSmall),
              subtitle: Text(e.value.map((v) => v.toStringAsFixed(1)).join('  ')),
            ),
        ],
      ),
    );
  }
}
