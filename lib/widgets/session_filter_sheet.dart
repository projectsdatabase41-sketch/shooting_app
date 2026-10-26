import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../i18n/i18n.dart';
import '../logic/session_filter.dart';
import '../services/ai_service.dart';
import '../services/ai_settings.dart';
import '../services/local_db_service.dart';
import 'glass_route.dart';

/// Шторка фильтра тренировок: поля вручную и строка «опишите словами» — её разбирает ИИ-помощник.
/// Возвращает новый фильтр (пустой — сброс) или `null`, если шторку закрыли.
Future<SessionFilter?> showSessionFilterSheet(BuildContext context, SessionFilter current, LocalDbService db) {
  return showGlassSheet<SessionFilter>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _FilterSheet(initial: current, db: db),
  );
}

class _FilterSheet extends StatefulWidget {
  final SessionFilter initial;
  final LocalDbService db;
  const _FilterSheet({required this.initial, required this.db});

  @override
  State<_FilterSheet> createState() => _FilterSheetState();
}

class _FilterSheetState extends State<_FilterSheet> {
  late SessionFilter f = SessionFilter(
    minScore: widget.initial.minScore,
    maxScore: widget.initial.maxScore,
    minShots: widget.initial.minShots,
    maxShots: widget.initial.maxShots,
    maxStpMm: widget.initial.maxStpMm,
    from: widget.initial.from,
    to: widget.initial.to,
    minMinutes: widget.initial.minMinutes,
    maxMinutes: widget.initial.maxMinutes,
    onlyWithNotes: widget.initial.onlyWithNotes,
  );
  final _ai = TextEditingController();
  bool _busy = false;
  String? _aiError;
  final _df = DateFormat('dd.MM.yyyy');

  @override
  void dispose() {
    _ai.dispose();
    super.dispose();
  }

  Future<void> _askAi() async {
    final text = _ai.text.trim();
    if (text.isEmpty) return;
    setState(() {
      _busy = true;
      _aiError = null;
    });
    try {
      final r = await AiService(AiSettings(widget.db)).ask(
        task: 'voice', // короткий разбор фразы — та же лёгкая модель, что у голосового помощника
        systemPrompt: SessionFilter.aiPrompt(DateTime.now()),
        contextBlock: '',
        history: [(role: 'user', text: text)],
        json: true,
        rotateKeys: true,
      );
      final parsed = SessionFilter.fromAiReply(r.text);
      if (!mounted) return;
      setState(() {
        if (parsed == null) {
          _aiError = tr('Не удалось понять условия — попробуйте иначе или задайте вручную');
        } else {
          f = parsed;
        }
      });
    } catch (_) {
      if (mounted) setState(() => _aiError = tr('ИИ-помощник сейчас недоступен — задайте условия вручную'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _num(String label, num? value, void Function(double?) set, {String? suffix}) {
    return Expanded(
      child: TextFormField(
        key: ValueKey('$label-${value ?? ''}'),
        initialValue: value == null ? '' : '${value % 1 == 0 ? value.toInt() : value}',
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: InputDecoration(labelText: label, suffixText: suffix, isDense: true),
        onChanged: (t) => set(double.tryParse(t.replaceAll(',', '.'))),
      ),
    );
  }

  Future<void> _pickDate(bool from) async {
    final now = DateTime.now();
    final d = await showDatePicker(
      context: context,
      initialDate: (from ? f.from : f.to) ?? now,
      firstDate: DateTime(2000),
      lastDate: DateTime(now.year + 1),
    );
    if (d != null && mounted) setState(() => from ? f.from = d : f.to = d);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    const gap = SizedBox(width: 12);
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.85),
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
            children: [
              Text(tr('Фильтр тренировок'), style: theme.textTheme.titleMedium),
              const SizedBox(height: 12),
              Row(children: [
                Expanded(
                  child: TextField(
                    controller: _ai,
                    textInputAction: TextInputAction.search,
                    onSubmitted: (_) => _askAi(),
                    decoration: InputDecoration(
                      labelText: tr('Опишите словами'),
                      hintText: tr('результат выше 600 за сентябрь, с заметками'),
                      isDense: true,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filledTonal(
                  tooltip: tr('Понять через ИИ'),
                  onPressed: _busy ? null : _askAi,
                  icon: _busy ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.auto_awesome_outlined),
                ),
              ]),
              if (_aiError != null) Padding(padding: const EdgeInsets.only(top: 6), child: Text(_aiError!, style: TextStyle(color: theme.colorScheme.error))),
              const SizedBox(height: 16),
              Row(children: [_num(tr('Результат от'), f.minScore, (v) => f.minScore = v), gap, _num(tr('до'), f.maxScore, (v) => f.maxScore = v)]),
              const SizedBox(height: 10),
              Row(children: [_num(tr('Выстрелов от'), f.minShots, (v) => f.minShots = v?.round()), gap, _num(tr('до'), f.maxShots, (v) => f.maxShots = v?.round())]),
              const SizedBox(height: 10),
              Row(children: [_num(tr('СТП не дальше'), f.maxStpMm, (v) => f.maxStpMm = v, suffix: tr('мм')), gap, const Expanded(child: SizedBox())]),
              const SizedBox(height: 10),
              Row(children: [
                _num(tr('Длительность от'), f.minMinutes, (v) => f.minMinutes = v?.round(), suffix: tr('мин')),
                gap,
                _num(tr('до'), f.maxMinutes, (v) => f.maxMinutes = v?.round(), suffix: tr('мин')),
              ]),
              const SizedBox(height: 10),
              Row(children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => _pickDate(true),
                    icon: const Icon(Icons.event),
                    label: Text(f.from == null ? tr('С даты') : _df.format(f.from!)),
                  ),
                ),
                gap,
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => _pickDate(false),
                    icon: const Icon(Icons.event),
                    label: Text(f.to == null ? tr('По дату') : _df.format(f.to!)),
                  ),
                ),
              ]),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(tr('Только с заметками к выстрелам')),
                value: f.onlyWithNotes,
                onChanged: (v) => setState(() => f.onlyWithNotes = v),
              ),
              const SizedBox(height: 8),
              Row(children: [
                TextButton(onPressed: () => Navigator.pop(context, SessionFilter()), child: Text(tr('Сбросить'))),
                const Spacer(),
                FilledButton(onPressed: () => Navigator.pop(context, f), child: Text(tr('Применить'))),
              ]),
            ],
          ),
        ),
      ),
    );
  }
}
