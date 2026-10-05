import 'dart:convert';

import 'package:flutter/material.dart';

import '../i18n/i18n.dart';
import '../widgets/ai_chart_view.dart';
import '../widgets/press_3d.dart';
import 'task_models.dart';

String stageModeLabel(StageMode m) => switch (m) {
      StageMode.single => tr('по порядку'),
      StageMode.together => tr('вместе'),
      StageMode.anyOrder => tr('все, порядок на выбор'),
      StageMode.pickOne => tr('один на выбор'),
    };

Color stageModeColor(BuildContext context, StageMode m) {
  final cs = Theme.of(context).colorScheme;
  return switch (m) {
    StageMode.single => cs.primary,
    StageMode.together => Colors.orange,
    StageMode.anyOrder => Colors.green,
    StageMode.pickOne => Colors.purple,
  };
}

String noteModeLabel(String m) => switch (m) {
      'shot' => tr('отметка к каждому выстрелу'),
      'series' => tr('отметка после каждой серии'),
      'none' => tr('без отметок'),
      _ => tr('отчёт в конце этапа'),
    };

String repeatLabel(String? rule) {
  if (rule == null || rule.isEmpty) return '';
  if (rule == 'daily') return tr('каждый день');
  const names = {
    'mon': 'пн',
    'tue': 'вт',
    'wed': 'ср',
    'thu': 'чт',
    'fri': 'пт',
    'sat': 'сб',
    'sun': 'вс'
  };
  return rule.split(',').map((d) => tr(names[d.trim()] ?? d)).join(', ');
}

/// Схема задания: ступени сверху вниз, у каждой — метка режима и этапы.
class TaskPlanView extends StatelessWidget {
  final TaskPlan plan;

  /// Подсветить ступень (текущая при выполнении); null — без подсветки.
  final int? current;
  const TaskPlanView({super.key, required this.plan, this.current});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final (i, stage) in plan.stages.indexed) ...[
          if (i > 0)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child:
                  Icon(Icons.arrow_downward, size: 18, color: theme.hintColor),
            ),
          Press3D(
            padding: const EdgeInsets.all(10),
            accent: current == null || current == i
                ? stageModeColor(context, stage.mode)
                : null,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(tr('Ступень {n}', {'n': i + 1}),
                        style: theme.textTheme.labelLarge),
                    const Spacer(),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                        color: stageModeColor(context, stage.mode)
                            .withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(stageModeLabel(stage.mode),
                          style: theme.textTheme.labelSmall?.copyWith(
                              color: stageModeColor(context, stage.mode))),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final s in stage.steps)
                      Chip(
                        visualDensity: VisualDensity.compact,
                        avatar: Icon(
                            s.isShooting
                                ? Icons.gps_fixed
                                : Icons.self_improvement,
                            size: 16),
                        label: Text(s.isShooting
                            ? '${s.title} · ${s.plannedShots}'
                            : s.title),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

/// Ступени «таблетками» над выполнением: выполнено / сейчас / закрыто.
class StageProgressPills extends StatelessWidget {
  final int count;

  /// Текущая ступень (null — обзор или итог).
  final int? current;
  final bool Function(int stage) isDone;
  const StageProgressPills(
      {super.key,
      required this.count,
      required this.current,
      required this.isDone});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      child: Row(
        children: [
          for (var i = 0; i < count; i++) ...[
            if (i > 0) const SizedBox(width: 6),
            () {
              final done = isDone(i);
              final now = current == i;
              final color =
                  done ? Colors.green : (now ? cs.primary : cs.outline);
              return AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: now ? 0.25 : 0.12),
                  borderRadius: BorderRadius.circular(999),
                  boxShadow: now
                      ? [
                          BoxShadow(
                              color: color.withValues(alpha: 0.35),
                              blurRadius: 8,
                              offset: const Offset(0, 3))
                        ]
                      : null,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                        done
                            ? Icons.check
                            : (now ? Icons.play_arrow : Icons.lock_outline),
                        size: 14,
                        color: color),
                    const SizedBox(width: 4),
                    Text('${i + 1}',
                        style: TextStyle(
                            color: color, fontWeight: FontWeight.w600)),
                  ],
                ),
              );
            }(),
          ],
        ],
      ),
    );
  }
}

/// Наглядный отчёт ИИ: JSON {"blocks":[{"type":"text"|"chart",…}]}.
class TaskVisualReport extends StatelessWidget {
  final String content;
  const TaskVisualReport({super.key, required this.content});

  @override
  Widget build(BuildContext context) {
    List blocks;
    try {
      blocks = (jsonDecode(content) as Map)['blocks'] as List? ?? const [];
    } catch (_) {
      return Text(content);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final b in blocks)
          if (b is Map && b['type'] == 'chart' && b['chart'] is Map)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: AiChartView(
                  spec: (b['chart'] as Map).cast<String, dynamic>()),
            )
          else if (b is Map)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Text('${b['text'] ?? ''}',
                  style: Theme.of(context).textTheme.bodyMedium),
            ),
      ],
    );
  }
}
