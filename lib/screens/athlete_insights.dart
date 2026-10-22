import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:intl/intl.dart';

import '../i18n/i18n.dart';
import '../services/coach_access_service.dart';
import '../services/coach_data_mapper.dart';
import '../services/local_db_service.dart';
import '../widgets/glass_pill.dart';
import '../widgets/glass_route.dart';

/// Локальные заметки тренера о спортсмене (группа, архив, цель, план). Хранятся только на этом
/// устройстве в таблице настроек; спортсмену и в облако не уходят.
class AthleteMeta {
  String group;
  bool archived;
  String goal;
  final List<PlanItem> plan;
  AthleteMeta({this.group = '', this.archived = false, this.goal = '', List<PlanItem>? plan}) : plan = plan ?? [];

  static String _key(String id) => 'coach_meta_$id';

  static AthleteMeta load(LocalDbService db, String id) {
    final r = db.db.select('SELECT hex FROM color_prefs WHERE key = ?', [_key(id)]);
    if (r.isEmpty) return AthleteMeta();
    try {
      final j = jsonDecode('${r.first['hex']}') as Map<String, dynamic>;
      return AthleteMeta(
        group: '${j['g'] ?? ''}',
        archived: j['a'] == true,
        goal: '${j['t'] ?? ''}',
        plan: [for (final p in (j['p'] as List? ?? const [])) PlanItem('${(p as Map)['d']}', '${p['n']}')],
      );
    } catch (_) {
      return AthleteMeta();
    }
  }

  void save(LocalDbService db, String id) => db.db.execute(
        'INSERT INTO color_prefs (key, hex) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET hex = excluded.hex',
        [
          _key(id),
          jsonEncode({
            'g': group,
            'a': archived,
            't': goal,
            'p': [for (final p in plan) {'d': p.date, 'n': p.note}],
          })
        ],
      );
}

class PlanItem {
  final String date; // yyyy-MM-dd
  final String note;
  const PlanItem(this.date, this.note);
}

/// Сводка по спортсмену из его открытых тренеру данных.
class AthleteStats {
  final ShareTokenStatus status;
  final DateTime? last;
  final int n7;
  final int n30;
  final double? avgShot; // средний результат выстрела по последним тренировкам
  final double? bestShot;
  final double? bestTotal; // лучшая сумма тренировки среди последних
  final int recentCount;
  const AthleteStats({required this.status, this.last, this.n7 = 0, this.n30 = 0, this.avgShot, this.bestShot, this.bestTotal, this.recentCount = 0});

  int? get daysSince => last == null ? null : DateTime.now().difference(last!).inDays;
}

/// Загружает сводку: статус доступа, даты тренировок и (по последним [recent]) результаты.
Future<AthleteStats> loadAthleteStats(CoachAccessService access, CoachAthlete a, {int recent = 3}) async {
  final status = await access.checkTokenStatusFor(a);
  if (status != ShareTokenStatus.valid) return AthleteStats(status: status);
  final packages = await access.fetchSessions(athlete: a);
  DateTime? when(Map<String, dynamic> p) => DateTime.tryParse('${p['started_at']}')?.toLocal();
  packages.sort((x, y) => (when(y) ?? DateTime(0)).compareTo(when(x) ?? DateTime(0)));
  final now = DateTime.now();
  var n7 = 0, n30 = 0;
  for (final p in packages) {
    final t = when(p);
    if (t == null) continue;
    final d = now.difference(t).inDays;
    if (d < 7) n7++;
    if (d < 30) n30++;
  }
  double? avg, bestShot, bestTotal;
  var count = 0;
  if (packages.isNotEmpty) {
    final exercises = await access.fetchExercises(athlete: a);
    final take = packages.take(recent).toList();
    final shots = <String, List<Map<String, dynamic>>>{};
    for (final p in take) {
      shots['${p['id']}'] = await access.fetchShots('${p['id']}', athlete: a);
    }
    final sessions = mapCoachSessions(take, exercises, shots).where((s) => s.countingShots.isNotEmpty).toList();
    count = sessions.length;
    final all = [for (final s in sessions) ...s.countingShots.map((x) => x.score)];
    if (all.isNotEmpty) {
      avg = all.reduce((x, y) => x + y) / all.length;
      bestShot = all.reduce((x, y) => x > y ? x : y);
      bestTotal = sessions.map((s) => s.totalScore).reduce((x, y) => x > y ? x : y);
    }
  }
  return AthleteStats(status: status, last: packages.isEmpty ? null : when(packages.first), n7: n7, n30: n30, avgShot: avg, bestShot: bestShot, bestTotal: bestTotal, recentCount: count);
}

String _ago(int? days) {
  if (days == null) return '—';
  if (days <= 0) return tr('сегодня');
  return tr('{n} дн. назад', {'n': days});
}

String weeklyReport(String name, AthleteStats s, AthleteMeta m) {
  final b = StringBuffer(tr('Отчёт за неделю: {name}', {'name': name}))..writeln();
  b.writeln(tr('Тренировок за 7 дней: {n}', {'n': s.n7}));
  b.writeln(tr('Тренировок за 30 дней: {n}', {'n': s.n30}));
  b.writeln(tr('Последняя тренировка: {d}', {'d': _ago(s.daysSince)}));
  if (s.avgShot != null) {
    b.writeln(tr('Средний выстрел (по {n} последним): {a}', {'n': s.recentCount, 'a': s.avgShot!.toStringAsFixed(2)}));
    b.writeln(tr('Лучший выстрел: {a}', {'a': s.bestShot!.toStringAsFixed(1)}));
    b.writeln(tr('Лучшая сумма: {a}', {'a': s.bestTotal!.toStringAsFixed(1)}));
  }
  if (m.goal.trim().isNotEmpty) b.writeln(tr('Цель: {g}', {'g': m.goal.trim()}));
  final upcoming = m.plan.where((p) => p.date.compareTo(DateFormat('yyyy-MM-dd').format(DateTime.now())) >= 0).toList()..sort((a, c) => a.date.compareTo(c.date));
  if (upcoming.isNotEmpty) {
    b.writeln(tr('План:'));
    for (final p in upcoming.take(5)) {
      b.writeln('• ${p.date} — ${p.note}');
    }
  }
  return b.toString().trim();
}

/// Карточка спортсмена: сводка, группа, цель, план, архив, отчёт за неделю. Меняет [meta] и сохраняет.
Future<void> showAthleteSheet(BuildContext context, {required LocalDbService db, required CoachAthlete athlete, required AthleteMeta meta, AthleteStats? stats, required Future<AthleteStats> Function() reload, required VoidCallback changed}) {
  return showGlassSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => _AthleteSheet(db: db, athlete: athlete, meta: meta, stats: stats, reload: reload, changed: changed),
  );
}

class _AthleteSheet extends StatefulWidget {
  final LocalDbService db;
  final CoachAthlete athlete;
  final AthleteMeta meta;
  final AthleteStats? stats;
  final Future<AthleteStats> Function() reload;
  final VoidCallback changed;
  const _AthleteSheet({required this.db, required this.athlete, required this.meta, required this.stats, required this.reload, required this.changed});

  @override
  State<_AthleteSheet> createState() => _AthleteSheetState();
}

class _AthleteSheetState extends State<_AthleteSheet> {
  AthleteStats? _stats;
  bool _loading = false;
  late final _goal = TextEditingController(text: widget.meta.goal);
  late final _group = TextEditingController(text: widget.meta.group);

  @override
  void initState() {
    super.initState();
    _stats = widget.stats;
    if (_stats == null) _refresh();
  }

  @override
  void dispose() {
    _commit();
    _goal.dispose();
    _group.dispose();
    super.dispose();
  }

  void _commit() {
    widget.meta.goal = _goal.text;
    widget.meta.group = _group.text.trim();
    widget.meta.save(widget.db, widget.athlete.id);
    widget.changed();
  }

  Future<void> _refresh() async {
    setState(() => _loading = true);
    try {
      final s = await widget.reload();
      if (mounted) setState(() => _stats = s);
    } catch (_) {
      if (mounted) setState(() => _stats = const AthleteStats(status: ShareTokenStatus.unknown));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _addPlan() async {
    final date = await showDatePicker(context: context, initialDate: DateTime.now(), firstDate: DateTime.now().subtract(const Duration(days: 1)), lastDate: DateTime.now().add(const Duration(days: 365)));
    if (date == null || !mounted) return;
    final ctl = TextEditingController();
    final note = await showGlassDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('Что запланировано')),
        content: TextField(controller: ctl, autofocus: true),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(), child: Text(tr('Отмена'))),
          FilledButton(onPressed: () => Navigator.of(ctx).pop(ctl.text.trim()), child: Text(tr('Сохранить'))),
        ],
      ),
    );
    if (note == null || note.isEmpty) return;
    setState(() => widget.meta.plan.add(PlanItem(DateFormat('yyyy-MM-dd').format(date), note)));
    _commit();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final s = _stats;
    final (statusText, statusColor) = switch (s?.status) {
      ShareTokenStatus.valid => (tr('Доступ действует'), Colors.green),
      ShareTokenStatus.revoked => (tr('Доступ отозван'), Colors.red),
      _ => (tr('Состояние доступа неизвестно'), Colors.grey),
    };
    final plan = [...widget.meta.plan]..sort((a, b) => a.date.compareTo(b.date));
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 0, 16, 16 + MediaQuery.viewInsetsOf(context).bottom),
      child: SingleChildScrollView(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Row(children: [
            Expanded(child: Text(widget.athlete.name, style: theme.textTheme.titleLarge)),
            IconButton(onPressed: _loading ? null : _refresh, icon: _loading ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.refresh), tooltip: tr('Обновить')),
          ]),
          Row(children: [Icon(Icons.circle, size: 10, color: statusColor), const SizedBox(width: 6), Text(statusText, style: theme.textTheme.bodySmall)]),
          const SizedBox(height: 10),
          if (s != null && s.status == ShareTokenStatus.valid) ...[
            Text('${tr('Последняя тренировка')}: ${_ago(s.daysSince)}'),
            Text('${tr('За 7 дней')}: ${s.n7} · ${tr('за 30 дней')}: ${s.n30}'),
            if (s.avgShot != null) Text('${tr('Средний выстрел')}: ${s.avgShot!.toStringAsFixed(2)} · ${tr('лучший')}: ${s.bestShot!.toStringAsFixed(1)} · ${tr('лучшая сумма')}: ${s.bestTotal!.toStringAsFixed(1)}'),
          ],
          const SizedBox(height: 12),
          TextField(controller: _group, decoration: InputDecoration(labelText: tr('Группа'))),
          const SizedBox(height: 8),
          TextField(controller: _goal, decoration: InputDecoration(labelText: tr('Цель или норматив')), maxLines: 2),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(tr('В архиве')),
            subtitle: Text(tr('Скрыт из списка, доступ и история остаются')),
            value: widget.meta.archived,
            onChanged: (v) {
              setState(() => widget.meta.archived = v);
              _commit();
            },
          ),
          Row(children: [
            Expanded(child: Text(tr('План'), style: theme.textTheme.titleSmall)),
            TextButton.icon(onPressed: _addPlan, icon: const Icon(Icons.add), label: Text(tr('Добавить'))),
          ]),
          if (plan.isEmpty) Text(tr('Пока ничего не запланировано'), style: theme.textTheme.bodySmall),
          for (final p in plan)
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: Text(p.note),
              subtitle: Text(p.date),
              trailing: IconButton(
                icon: const Icon(Icons.close),
                onPressed: () {
                  setState(() => widget.meta.plan.remove(p));
                  _commit();
                },
              ),
            ),
          const SizedBox(height: 8),
          FilledButton.icon(
            onPressed: s == null
                ? null
                : () async {
                    _commit();
                    await Clipboard.setData(ClipboardData(text: weeklyReport(widget.athlete.name, s, widget.meta)));
                    if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('Отчёт скопирован — вставьте его в чат'))));
                  },
            icon: const Icon(Icons.summarize_outlined),
            label: Text(tr('Отчёт за неделю')),
          ),
        ]),
      ),
    );
  }
}

/// Сравнение нескольких спортсменов рядом.
class AthleteCompareScreen extends StatefulWidget {
  final CoachAccessService access;
  final List<CoachAthlete> athletes;
  const AthleteCompareScreen({super.key, required this.access, required this.athletes});

  @override
  State<AthleteCompareScreen> createState() => _AthleteCompareScreenState();
}

class _AthleteCompareScreenState extends State<AthleteCompareScreen> {
  final Map<String, AthleteStats?> _stats = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    for (final a in widget.athletes) {
      try {
        final s = await loadAthleteStats(widget.access, a, recent: 5);
        if (mounted) setState(() => _stats[a.id] = s);
      } catch (_) {
        if (mounted) setState(() => _stats[a.id] = const AthleteStats(status: ShareTokenStatus.unknown));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final topInset = MediaQuery.paddingOf(context).top;
    final best = [for (final s in _stats.values) if (s?.avgShot != null) s!.avgShot!];
    final maxAvg = best.isEmpty ? 1.0 : best.reduce((a, b) => a > b ? a : b);
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: GlassHeader(title: Text(tr('Сравнение'), style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600))),
      body: ListView(
        padding: EdgeInsets.fromLTRB(16, topInset + GlassHeader.height + 8, 16, 24),
        children: [
          for (final a in widget.athletes)
            Card(
              margin: const EdgeInsets.only(bottom: 10),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Builder(builder: (_) {
                  final s = _stats[a.id];
                  if (!_stats.containsKey(a.id)) {
                    return Row(children: [Expanded(child: Text(a.name, style: theme.textTheme.titleSmall)), const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))]);
                  }
                  return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(a.name, style: theme.textTheme.titleSmall),
                    const SizedBox(height: 6),
                    if (s == null || s.status != ShareTokenStatus.valid)
                      Text(tr('Нет доступа к данным'), style: theme.textTheme.bodySmall)
                    else ...[
                      Text('${tr('Последняя')}: ${_ago(s.daysSince)} · 7 ${tr('дн.')}: ${s.n7} · 30 ${tr('дн.')}: ${s.n30}', style: theme.textTheme.bodySmall),
                      if (s.avgShot != null) ...[
                        const SizedBox(height: 6),
                        LinearProgressIndicator(value: (s.avgShot! / maxAvg).clamp(0.0, 1.0), minHeight: 8),
                        const SizedBox(height: 4),
                        Text('${tr('Средний выстрел')}: ${s.avgShot!.toStringAsFixed(2)} · ${tr('лучшая сумма')}: ${s.bestTotal!.toStringAsFixed(1)}', style: theme.textTheme.bodySmall),
                      ],
                    ],
                  ]);
                }),
              ),
            ),
        ],
      ),
    );
  }
}
