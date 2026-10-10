import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../finals/bot.dart';
import '../finals/final_engine.dart';
import '../finals/final_run.dart';
import '../finals/finals_repository.dart';
import '../i18n/i18n.dart';
import '../models/target_face.dart';
import '../state/app_data_store.dart';
import '../widgets/glass_pill.dart';
import 'final_run_screen.dart';

/// Вкладка «Финалы»: форматы по правилам ISSF и история своих финалов.
class FinalsScreen extends StatefulWidget {
  const FinalsScreen({super.key});

  @override
  State<FinalsScreen> createState() => _FinalsScreenState();
}

class _FinalsScreenState extends State<FinalsScreen> {
  @override
  Widget build(BuildContext context) {
    final store = context.read<AppDataStore>();
    final repo = FinalsRepository(store.db);
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final history = repo.list();
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: GlassHeader(
        leading: const SizedBox.shrink(),
        title: Text(tr('Финалы'), style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
      ),
      body: ListView(
        padding: EdgeInsets.fromLTRB(16, MediaQuery.paddingOf(context).top + GlassHeader.height + 8, 16, 24),
        children: [
          Text(tr('Выберите финал'), style: theme.textTheme.titleSmall),
          const SizedBox(height: 8),
          for (final f in FinalFormat.all)
            Card(
              margin: const EdgeInsets.only(bottom: 10),
              child: ListTile(
                contentPadding: const EdgeInsets.fromLTRB(16, 8, 12, 8),
                leading: CircleAvatar(
                  backgroundColor: cs.primary.withValues(alpha: 0.18),
                  child: Icon(Icons.emoji_events_outlined, color: cs.primary),
                ),
                title: Text(tr(f.nameKey)),
                subtitle: Text(tr('{n} финалистов · {shots} выстрела · десятые доли', {'n': f.finalists, 'shots': f.totalShots})),
                trailing: const Icon(Icons.chevron_right),
                onTap: () async {
                  await Navigator.of(context).push(MaterialPageRoute(builder: (_) => FinalSetupScreen(format: f)));
                  if (mounted) setState(() {});
                },
              ),
            ),
          const SizedBox(height: 12),
          Text(tr('Мои финалы'), style: theme.textTheme.titleSmall),
          const SizedBox(height: 8),
          if (history.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Text(tr('Пока нет финалов'), textAlign: TextAlign.center, style: theme.textTheme.bodyMedium),
            )
          else
            for (final r in history)
              Card(
                margin: const EdgeInsets.only(bottom: 8),
                child: ListTile(
                  leading: CircleAvatar(
                    backgroundColor: (r.userPlace ?? 9) <= 3 ? const Color(0xFFD9A441) : cs.surfaceContainerHigh,
                    child: Text('${r.userPlace ?? '—'}', style: const TextStyle(fontWeight: FontWeight.w800)),
                  ),
                  title: Text(tr(FinalFormat.all.firstWhere((f) => f.id == r.formatId, orElse: () => FinalFormat.airRifle10m).nameKey)),
                  subtitle: Text('${r.finishedAt.toLocal().toString().substring(0, 16)} · ${r.userTotal.toStringAsFixed(1)}'),
                  onTap: () => Navigator.of(context)
                      .push(MaterialPageRoute(builder: (_) => FinalResultScreen(record: r.data))),
                ),
              ),
        ],
      ),
    );
  }
}

/// Настройка финала: соперники, сложность, скорость; показывает, по каким
/// данным тренировок будут стрелять боты.
class FinalSetupScreen extends StatefulWidget {
  final FinalFormat format;
  const FinalSetupScreen({super.key, required this.format});

  @override
  State<FinalSetupScreen> createState() => _FinalSetupScreenState();
}

class _FinalSetupScreenState extends State<FinalSetupScreen> {
  String _level = 'mixed'; // mixed | easy | medium | hard | unpredictable
  int _speed = 1;

  static const _names = ['Алексей', 'Мария', 'Игорь', 'Елена', 'Сергей', 'Ольга', 'Дмитрий'];

  /// Выстрелы тренировок на мишени этого финала.
  ({List<(double, double)> all, List<ShotStats> sessions}) _history(AppDataStore store) {
    final all = <(double, double)>[];
    final per = <ShotStats>[];
    for (final s in store.sessions) {
      if (s.targetFaceCode != widget.format.faceCode) continue;
      final pts = [for (final sh in s.countingShots) (sh.xMm, sh.yMm)];
      all.addAll(pts);
      if (pts.length >= 5) per.add(ShotStats.fromPoints(pts));
    }
    return (all: all, sessions: per);
  }

  /// Статистика по умолчанию, пока своих тренировок мало.
  ShotStats get _fallback => widget.format.faceCode == 'pistol_10m'
      ? const ShotStats(0, 0, 9.0, 9.0, 0)
      : const ShotStats(0, 0, 3.5, 3.5, 0);

  void _start(AppDataStore store) {
    final face = TargetFace.byCode(widget.format.faceCode);
    final h = _history(store);
    final enough = h.all.length >= 20;
    final stats = enough ? ShotStats.fromPoints(h.all) : _fallback;
    final rng = math.Random();
    const mixed = [
      BotDifficulty.easy,
      BotDifficulty.easy,
      BotDifficulty.medium,
      BotDifficulty.medium,
      BotDifficulty.hard,
      BotDifficulty.hard,
      BotDifficulty.unpredictable,
    ];
    final levels = _level == 'mixed'
        ? ([...mixed]..shuffle(rng))
        : List.filled(7, BotDifficulty.values.firstWhere((d) => d.name == _level));
    final competitors = [
      FinalCompetitor('me', tr('Вы'), isUser: true),
      for (var i = 0; i < 7; i++) FinalCompetitor('b$i', _names[i]),
    ];
    final controller = FinalRunController(
      format: widget.format,
      face: face,
      engine: FinalEngine(widget.format, competitors),
      userId: 'me',
      bots: {
        for (var i = 0; i < 7; i++)
          'b$i': BotShooter(stats, levels[i], face, math.Random(rng.nextInt(1 << 30)), sessions: h.sessions),
      },
      rng: rng,
    );
    Navigator.of(context).pushReplacement(MaterialPageRoute(
      builder: (_) => FinalRunScreen(controller: controller, speed: _speed, store: store),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final store = context.read<AppDataStore>();
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final f = widget.format;
    final h = _history(store);
    final enough = h.all.length >= 20;
    Widget chips<T>(List<(T, String)> items, T value, ValueChanged<T> onPick) => Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final it in items)
              ChoiceChip(label: Text(it.$2), selected: it.$1 == value, onSelected: (_) => setState(() => onPick(it.$1))),
          ],
        );
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: GlassHeader(
        title: Text(tr(f.nameKey), style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600), overflow: TextOverflow.ellipsis),
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView(
              padding: EdgeInsets.fromLTRB(16, MediaQuery.paddingOf(context).top + GlassHeader.height + 8, 16, 16),
              children: [
                // 1. Правила.
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(color: cs.surfaceContainerHigh, borderRadius: BorderRadius.circular(18)),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(tr('По правилам ISSF (п. 6.17.2)'), style: theme.textTheme.titleSmall),
                    const SizedBox(height: 6),
                    Text(
                      tr('Подготовка и пристрелка 5 минут, затем две серии по 5 выстрелов (по 250 с) и 14 одиночных выстрелов (по 50 с). Десятые доли. После 12-го выстрела и далее после каждых двух выбывает самый слабый; при ничьей — перестрелка.'),
                      style: theme.textTheme.bodySmall,
                    ),
                  ]),
                ),
                const SizedBox(height: 18),
                // 2. Соперники.
                Text(tr('Соперники (7 ботов)'), style: theme.textTheme.titleSmall),
                const SizedBox(height: 8),
                chips<String>([
                  ('mixed', tr('Разные')),
                  ('easy', tr('Лёгкие')),
                  ('medium', tr('Средние')),
                  ('hard', tr('Сложные')),
                  ('unpredictable', tr('Непредсказуемые')),
                ], _level, (v) => _level = v),
                const SizedBox(height: 18),
                // 3. Скорость.
                Text(tr('Скорость'), style: theme.textTheme.titleSmall),
                const SizedBox(height: 8),
                chips<int>([(1, tr('Как в жизни')), (5, tr('Быстрее ×5')), (20, tr('Очень быстро ×20'))], _speed, (v) => _speed = v),
                const SizedBox(height: 18),
                // 4. Откуда данные ботов.
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: (enough ? cs.primary : cs.error).withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Icon(enough ? Icons.insights_outlined : Icons.info_outline, color: enough ? cs.primary : cs.error),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        enough
                            ? tr('Боты стреляют по вашим тренировкам на этой мишени: {n} выстрелов, учитываются средняя точка попадания, направление смещения и разброс.', {'n': h.all.length})
                            : tr('На этой мишени у вас мало выстрелов в тренировках ({n}). Боты будут стрелять по типичным для спортсмена значениям; после 20 выстрелов — по вашим.', {'n': h.all.length}),
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                  ]),
                ),
              ],
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 14),
              child: SizedBox(
                width: double.infinity,
                height: 52,
                child: FilledButton.icon(
                  onPressed: () => _start(store),
                  icon: const Icon(Icons.play_arrow),
                  label: Text(tr('Начать финал')),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
