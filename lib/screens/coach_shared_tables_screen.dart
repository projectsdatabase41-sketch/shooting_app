import 'dart:convert';

import 'package:flutter/material.dart';

import '../i18n/i18n.dart';
import '../logic/friendly_error.dart';
import '../services/coach_access_service.dart';
import '../widgets/glass_pill.dart';

/// Таблицы личной базы спортсмена, которые он открыл тренеру
/// («расширенный» токен, sql/share-policy.sql): список таблиц и строки
/// каждой по нажатию.
class CoachSharedTablesScreen extends StatelessWidget {
  final CoachAccessService access;
  final List<String> tables;
  final String athleteName;

  const CoachSharedTablesScreen(
      {super.key,
      required this.access,
      required this.tables,
      required this.athleteName});

  @override
  Widget build(BuildContext context) {
    final topInset = MediaQuery.paddingOf(context).top;
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: GlassHeader(
        title: Text(tr('Таблицы: {n}', {'n': athleteName}),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context)
                .textTheme
                .titleMedium
                ?.copyWith(fontWeight: FontWeight.w600)),
      ),
      body: ListView(
        padding: EdgeInsets.only(top: topInset + GlassHeader.height),
        children: [
          for (final t in tables) _TableTile(access: access, table: t)
        ],
      ),
    );
  }
}

class _TableTile extends StatefulWidget {
  final CoachAccessService access;
  final String table;
  const _TableTile({required this.access, required this.table});

  @override
  State<_TableTile> createState() => _TableTileState();
}

class _TableTileState extends State<_TableTile> {
  List<Map<String, dynamic>>? _rows;
  String? _error;
  bool _loading = false;

  Future<void> _load() async {
    if (_rows != null || _loading) return;
    setState(() => _loading = true);
    try {
      final rows = await widget.access.fetchSharedTable(widget.table);
      if (mounted) setState(() => _rows = rows);
    } catch (e) {
      if (mounted) setState(() => _error = friendlyError(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ExpansionTile(
      leading: const Icon(Icons.table_chart_outlined),
      title: Text(widget.table),
      subtitle:
          _rows == null ? null : Text(tr('Строк: {n}', {'n': _rows!.length})),
      onExpansionChanged: (open) {
        if (open) _load();
      },
      children: [
        if (_loading)
          const Padding(
              padding: EdgeInsets.all(16), child: CircularProgressIndicator()),
        if (_error != null)
          Padding(
              padding: const EdgeInsets.all(16),
              child: Text(_error!,
                  style: TextStyle(color: theme.colorScheme.error))),
        for (final r in _rows ?? const <Map<String, dynamic>>[])
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: SelectableText(
              r.entries
                  .where((e) => e.value != null)
                  .map((e) =>
                      '${e.key}: ${e.value is String ? e.value : jsonEncode(e.value)}')
                  .join('\n'),
              style: theme.textTheme.bodySmall,
            ),
          ),
      ],
    );
  }
}
