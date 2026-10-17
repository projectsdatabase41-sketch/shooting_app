import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../i18n/i18n.dart';
import '../logic/ai_context.dart';
import '../logic/friendly_error.dart';
import '../models/training_session.dart';
import '../services/ai_service.dart';
import '../services/ai_settings.dart';
import '../state/app_data_store.dart';
import 'ai_chart_view.dart';
import 'ai_gate.dart';

/// «Мои графики» в статистике: опишите, какой график нужен, — ИИ строит его по
/// тренировкам (своим или выбранного спортсмена); готовые графики сохраняются и
/// показываются в конце статистики. Только при включённом модуле ИИ.
class AiChartsSection extends StatefulWidget {
  final List<TrainingSession> sessions;
  final String Function(TrainingSession) nameOf;

  /// Чьи данные: `null` — свои; иначе имя спортсмена (ключ хранения и подпись в контексте).
  final String? ownerLabel;
  const AiChartsSection({super.key, required this.sessions, required this.nameOf, this.ownerLabel});

  @override
  State<AiChartsSection> createState() => _AiChartsSectionState();
}

class _AiChartsSectionState extends State<AiChartsSection> {
  List<Map<String, dynamic>> _items = [];
  bool _busy = false;
  String? _error;

  String get _key => 'stats_ai_charts_${widget.ownerLabel ?? 'me'}';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(AiChartsSection old) {
    super.didUpdateWidget(old);
    if (old.ownerLabel != widget.ownerLabel) _load();
  }

  void _load() {
    try {
      final db = context.read<AppDataStore>().db;
      final rows = db.db.select('SELECT hex FROM color_prefs WHERE key = ?', [_key]);
      _items = rows.isEmpty
          ? []
          : [for (final e in jsonDecode('${rows.first['hex']}') as List) (e as Map).cast<String, dynamic>()];
    } catch (_) {
      _items = [];
    }
  }

  void _save() {
    final db = context.read<AppDataStore>().db;
    db.db.execute(
        'INSERT INTO color_prefs (key, hex) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET hex = excluded.hex',
        [_key, jsonEncode(_items)]);
  }

  Future<void> _create() async {
    final ctl = TextEditingController();
    final text = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('График с ИИ')),
        content: TextField(
          controller: ctl,
          autofocus: true,
          minLines: 2,
          maxLines: 5,
          decoration: InputDecoration(
              hintText: tr('Например: средний результат по неделям за последние 3 месяца; или сравнение упражнений по кучности')),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('Отмена'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, ctl.text.trim()), child: Text(tr('Построить'))),
        ],
      ),
    );
    if (text == null || text.isEmpty || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final store = context.read<AppDataStore>();
      final ctx = AiContext(
        scope: AiScope.general,
        allSessions: widget.sessions,
        exerciseNameOf: widget.nameOf,
        ownerLabel: widget.ownerLabel,
        existingExercises: store.exercises,
      );
      final reply = await AiService(AiSettings(store.db)).ask(
        task: 'chat',
        systemPrompt: "You build ONE chart for the statistics screen of a shooting-sports app from the user's request and the data in the context. "
            'Use ONLY numbers present in the context (training_history: dates, totals, averages, shots); never invent data. '
            'Reply with a one-line caption and ONE fenced block ```chart with JSON: '
            '{"type":"line|bar|pie|table","title":"...","x":["..."],"series":[{"name":"...","values":[numbers]}]} '
            'or for a table {"type":"table","title":"...","columns":["..."],"rows":[["..."]]}. '
            'Titles and labels in the language of the request. Keep it compact: at most 30 points.',
        contextBlock: ctx.buildContextBlock(DateTime.now()),
        history: [(role: 'user', text: text)],
      );
      final chart = reply.chart;
      if (chart == null) throw Exception(tr('ИИ не построил график — уточните запрос'));
      setState(() {
        _items.insert(0, {'prompt': text, 'spec': chart});
        _save();
      });
    } catch (e) {
      setState(() => _error = friendlyError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!aiModuleOn(context)) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const SizedBox(height: 16),
      Row(children: [
        Expanded(child: Text(tr('Мои графики'), style: theme.textTheme.titleMedium)),
        FilledButton.tonalIcon(
          onPressed: _busy || widget.sessions.isEmpty ? null : _create,
          icon: _busy
              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.auto_awesome),
          label: Text(tr('График с ИИ')),
        ),
      ]),
      if (_error != null)
        Padding(padding: const EdgeInsets.only(top: 8), child: Text(_error!, style: TextStyle(color: theme.colorScheme.error))),
      for (var i = 0; i < _items.length; i++)
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Stack(children: [
            AiChartView(spec: (_items[i]['spec'] as Map).cast<String, dynamic>()),
            Positioned(
              right: 4,
              top: 4,
              child: IconButton(
                tooltip: tr('Удалить график'),
                icon: const Icon(Icons.close, size: 18),
                onPressed: () => setState(() {
                  _items.removeAt(i);
                  _save();
                }),
              ),
            ),
          ]),
        ),
    ]);
  }
}
