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
import '../finals/champions_service.dart';
import '../services/chat_auth_service.dart';
import 'champions_screen.dart';
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
          Card(
            child: ListTile(
              leading: const Icon(Icons.military_tech_outlined),
              title: Text(tr('Чемпионы')),
              subtitle: Text(tr('Опубликованные результаты и подпись тренера')),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ChampionsScreen())),
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
  bool _custom = false; // свой финал: не публикуется
  late String _layout = FinalsPrefs.layout(context.read<AppDataStore>().db);

  // Семь соперников: обычные боты или чемпионы (по их статистике).
  late final List<_Opp> _opps = [for (final n in _names) _Opp(n)];

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
  ShotStats get _fallback => switch (widget.format.faceCode) {
        'pistol_10m' => const ShotStats(0, 0, 9.0, 9.0, 0),
        'rifle_50m' => const ShotStats(0, 0, 6.0, 6.0, 0),
        _ => const ShotStats(0, 0, 3.5, 3.5, 0),
      };

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
      for (var i = 0; i < 7; i++) FinalCompetitor('b$i', '${_opps[i].name} (Bot)'),
    ];
    final controller = FinalRunController(
      format: widget.format,
      face: face,
      engine: FinalEngine(widget.format, competitors),
      userId: 'me',
      bots: {
        for (var i = 0; i < 7; i++)
          'b$i': BotShooter(_opps[i].stats ?? stats, _opps[i].stats != null ? BotDifficulty.medium : levels[i], face,
              math.Random(rng.nextInt(1 << 30)),
              sessions: h.sessions),
      },
      rng: rng,
    );
    Navigator.of(context).pushReplacement(MaterialPageRoute(
      builder: (_) => FinalRunScreen(controller: controller, store: store, custom: _custom),
    ));
  }

  /// Выбор чемпиона из таблицы и замена им одного из участников.
  Future<void> _addChampion(AppDataStore store) async {
    final list = await ChampionsService(ChatAuthService(store.db)).champions(widget.format.id);
    if (!mounted) return;
    if (list.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('В таблице пока нет чемпионов'))));
      return;
    }
    final champ = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      builder: (ctx) => ListView(children: [
        for (final r in list)
          ListTile(
            title: Text('${r['display_name']}'),
            trailing: Text((r['total'] as num).toStringAsFixed(1)),
            onTap: () => Navigator.pop(ctx, r),
          ),
      ]),
    );
    if (champ == null || !mounted) return;
    // Восьмой участник не помещается: предлагаем убрать лишнего.
    final slot = await showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('Максимум 8 участников')),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView(shrinkWrap: true, children: [
            Text(tr('Выберите, кого убрать, чтобы добавить {n}', {'n': champ['display_name']})),
            for (var i = 0; i < _opps.length; i++)
              ListTile(
                dense: true,
                title: Text(_opps[i].name),
                subtitle: Text(_opps[i].stats == null ? tr('Бот') : tr('Чемпион')),
                trailing: const Icon(Icons.delete_outline),
                onTap: () => Navigator.pop(ctx, i),
              ),
          ]),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('Отмена')))],
      ),
    );
    if (slot == null) return;
    final st = champ['stats'] as Map<String, dynamic>;
    double n(String k) => (st[k] as num).toDouble();
    setState(() => _opps[slot] = _Opp('${champ['display_name']}',
        stats: ShotStats(n('mx'), n('my'), n('sx'), n('sy'), (st['n'] as num).toInt())));
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
                    Text(tr(f.hasOpenStage ? 'По правилам ISSF (п. 6.17.3)' : 'По правилам ISSF (п. 6.17.2)'), style: theme.textTheme.titleSmall),
                    const SizedBox(height: 6),
                    Text(
                      f.hasOpenStage
                          ? tr('Подготовка и пристрелка 5 минут, затем 10 выстрелов с колена и 10 лёжа за 22 минуты. Стоя две серии по 5 выстрелов (по 250 с), после 30-го выстрела выбывают двое, дальше одиночные по 50 с: после каждого выбывает самый слабый. Десятые доли, всего 35 выстрелов.')
                          : tr('Подготовка и пристрелка 5 минут, затем две серии по 5 выстрелов (по 250 с) и 14 одиночных выстрелов (по 50 с). Десятые доли. После 12-го выстрела и далее после каждых двух выбывает самый слабый; при ничьей — перестрелка.'),
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
                  ('champions', tr('Чемпионы (недостающих заменят боты)')),
                ], _level, (v) => _level = v),
                const SizedBox(height: 18),
                // Участники.
                Text(tr('Участники'), style: theme.textTheme.titleSmall),
                const SizedBox(height: 4),
                for (var i = 0; i < _opps.length; i++)
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(_opps[i].stats == null ? Icons.smart_toy_outlined : Icons.emoji_events_outlined, size: 20),
                    title: Text('${_opps[i].name} (Bot)'),
                    trailing: _opps[i].stats == null
                        ? null
                        : IconButton(
                            icon: const Icon(Icons.close, size: 18),
                            tooltip: tr('Вернуть простого бота'),
                            onPressed: () => setState(() => _opps[i] = _Opp(_names[i])),
                          ),
                  ),
                OutlinedButton.icon(
                  onPressed: () => _addChampion(store),
                  icon: const Icon(Icons.add),
                  label: Text(tr('Добавить чемпиона')),
                ),
                const SizedBox(height: 18),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(tr('Свой финал')),
                  subtitle: Text(tr('Результат не публикуется и не влияет на рейтинг')),
                  value: _custom,
                  onChanged: (v) => setState(() => _custom = v),
                ),
                const SizedBox(height: 18),
                // Вид экрана.
                Text(tr('Вид экрана финала'), style: theme.textTheme.titleSmall),
                const SizedBox(height: 8),
                chips<String>([
                  ('classic', tr('Мишень сверху, боты ниже')),
                  ('side', tr('Большая мишень и три бота справа')),
                ], _layout, (v) {
                  _layout = v;
                  FinalsPrefs.setLayout(store.db, v);
                }),
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

class _Opp {
  final String name;
  final ShotStats? stats; // null — обычный бот по вашим тренировкам
  _Opp(this.name, {this.stats});
}
