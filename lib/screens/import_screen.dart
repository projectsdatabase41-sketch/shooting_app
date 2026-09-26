import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../models/target_face.dart';
import '../services/session_import.dart';
import '../state/app_data_store.dart';
import '../widgets/section_header.dart';
import '../i18n/i18n.dart';

/// Импорт тренировок из файла.
///
/// Экран нарочно двухшаговый: сначала показать, ЧТО приедет в базу, и
/// только потом писать. Импорт добавляет тренировки целыми пачками, и
/// «ой, не тот файл» после записи разгребается вручную по одной
/// тренировке.
class ImportScreen extends StatefulWidget {
  const ImportScreen({super.key});

  @override
  State<ImportScreen> createState() => _ImportScreenState();
}

class _ImportScreenState extends State<ImportScreen> {
  ImportBundle? _bundle;
  String? _error;
  String? _fileName;
  bool _busy = false;
  int? _applied;

  Future<void> _pick() async {
    setState(() {
      _busy = true;
      _error = null;
      _applied = null;
    });
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['json'],
        // Байты просим всегда, а не только на вебе: в браузере файла на
        // диске просто нет, а `dart:io` в веб-сборку не компилируется.
        // Читать один и тот же путь на всех платформах дешевле, чем
        // держать две ветки — файл импорта весит десятки килобайт.
        withData: true,
      );
      if (result == null || result.files.isEmpty) {
        setState(() => _busy = false);
        return;
      }
      final file = result.files.first;
      final bytes = file.bytes;
      if (bytes == null) {
        throw ImportException(tr('Не удалось прочитать файл'));
      }
      final raw = utf8.decode(bytes);
      final bundle = SessionImport.parse(raw);
      setState(() {
        _bundle = bundle;
        _fileName = file.name;
        _busy = false;
      });
    } on ImportException catch (e) {
      setState(() {
        _error = e.message;
        _bundle = null;
        _busy = false;
      });
    } catch (e) {
      setState(() {
        _error = '$e';
        _bundle = null;
        _busy = false;
      });
    }
  }

  void _apply() {
    final bundle = _bundle;
    if (bundle == null) return;
    final store = context.read<AppDataStore>();
    final added = SessionImport.apply(store, bundle);
    setState(() {
      _applied = added;
      _bundle = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final bundle = _bundle;
    final df = DateFormat('dd.MM.yyyy HH:mm');

    return Scaffold(
      appBar: AppBar(title: Text(tr('Импорт тренировок'))),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        children: [
          SectionHeader(
            title: tr('Файл'),
            subtitle: tr('JSON с тренировками. Записывается только после подтверждения.'),
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: _busy ? null : _pick,
            icon: _busy
                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.folder_open),
            label: Text(_fileName ?? tr('Выбрать файл')),
          ),
          if (_error != null) ...[
            const SizedBox(height: 16),
            Card(
              color: cs.errorContainer,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.error_outline, size: 18, color: cs.onErrorContainer),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _error!,
                        style: theme.textTheme.bodyMedium?.copyWith(color: cs.onErrorContainer),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
          if (_applied != null) ...[
            const SizedBox(height: 16),
            Card(
              color: cs.secondaryContainer,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  children: [
                    Icon(Icons.check_circle_outline, size: 18, color: cs.onSecondaryContainer),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        tr('Добавлено тренировок: {applied}. Смотрите на вкладке «История».', {'applied': _applied}),
                        style: theme.textTheme.bodyMedium?.copyWith(color: cs.onSecondaryContainer),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
          if (bundle != null) ...[
            const SizedBox(height: 24),
            SectionHeader(
              title: tr('Что будет добавлено'),
              subtitle: tr('Источник: {source} · тренировок {length}, выстрелов {shotCount}', {'source': bundle.source, 'length': bundle.sessions.length, 'shotCount': bundle.shotCount}),
            ),
            const SizedBox(height: 12),
            for (final s in bundle.sessions)
              Card(
                child: ListTile(
                  title: Text(s.label),
                  subtitle: Text(
                    tr('{p} · {p2}\nвыстрелов {length}, сумма {p3}', {'p': s.session.startedAt == null ? '—' : df.format(s.session.startedAt!), 'p2': TargetFace.byCode(s.targetFaceCode).name, 'length': s.session.shots.length, 'p3': s.session.totalScore.toStringAsFixed(1)}),
                  ),
                  isThreeLine: true,
                ),
              ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _apply,
              icon: const Icon(Icons.download_done),
              label: Text(tr('Добавить {length} в базу', {'length': bundle.sessions.length})),
            ),
          ],
          const SizedBox(height: 24),
          Text(
            tr('Импортированные выстрелы помечаются как правленые вручную: результат берётся из отчёта прибора и не пересчитывается по координатам. Показатели, которым нет места в таблицах (время прицеливания, удержание, скорость), сохраняются рядом с выстрелом и доступны ассистенту.'),
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}
