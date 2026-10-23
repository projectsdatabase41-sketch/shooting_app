import '../widgets/glass_route.dart';
import '../widgets/app_backdrop.dart';
import 'finals_voice_settings_screen.dart';
import '../finals/voice_packs.dart';
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
import '../finals/finals_session_service.dart';
import '../services/user_profile.dart';
import 'champions_screen.dart';
import '../finals/finals_invite.dart';
import 'final_room_screens.dart';
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
        title: Text(tr('Финалы'), style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
      ),
      body: AppBackdrop(kind: 'finals', child: ListView(
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
          // Совместные финалы: провести самому (тренер) или войти по приглашению.
          const SizedBox(height: 4),
          Text(tr('Финалы с участниками'), style: theme.textTheme.titleSmall),
          const SizedBox(height: 8),
          // Проводить финалы может тренер — только при включённом модуле «Я тренер».
          if (store.isCoach)
            Card(
            child: ListTile(
              leading: const Icon(Icons.groups_outlined),
              title: Text(tr('Провести финал (тренер)')),
              subtitle: Text(tr('Пригласите спортсменов и помощников, подавайте команды кнопкой «Далее»')),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _hostFinal(context),
            ),
          ),
          _Invites(store: store),
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
                  trailing: IconButton(
                    tooltip: tr('Удалить финал'),
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () async {
                      final ok = await showGlassDialog<bool>(
                        context: context,
                        builder: (ctx) => AlertDialog(
                          title: Text(tr('Удалить финал?')),
                          content: Text(tr('Запись о финале будет удалена с этого устройства.')),
                          actions: [
                            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('Отмена'))),
                            TextButton(onPressed: () => Navigator.pop(ctx, true), child: Text(tr('Удалить'))),
                          ],
                        ),
                      );
                      if (ok == true) setState(() => repo.delete(r.id));
                    },
                  ),
                  onTap: () => Navigator.of(context)
                      .push(MaterialPageRoute(builder: (_) => FinalResultScreen(record: r.data))),
                ),
              ),
        ],
      )),
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
  int _cSeries = 2, _cPerSeries = 5, _cSingles = 14, _cSeriesSec = 250, _cSingleSec = 50, _cStep = 2;

  /// Формат: выбранный или собранный конструктором (`null` — параметры неверны).
  FinalFormat? get _fmt => _custom
      ? FinalFormat.custom(
          faceCode: widget.format.faceCode,
          series: _cSeries,
          perSeries: _cPerSeries,
          singles: _cSingles,
          seriesSeconds: _cSeriesSec,
          singleSeconds: _cSingleSec,
          step: _cStep,
        )
      : widget.format;
  late bool _voice = FinalsPrefs.voice(context.read<AppDataStore>().db);
  late bool _voiceAll = FinalsPrefs.voiceAll(context.read<AppDataStore>().db);

  // Семь соперников: обычные боты или чемпионы (по их статистике).
  late final List<_Opp> _opps = [for (final n in _names) _Opp(n)];

  static const _names = ['Бывалый', 'Татошка', 'Кость', 'Я в свое время тоже стрельбой занимался', 'Рыцарь', 'Сахарок', 'Усталый'];

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

  /// Имя и фамилия из профиля; без них — ник мессенджера или «Вы».
  String _myName(AppDataStore store) {
    final first = UserProfile.firstNameOf(store.db), last = UserProfile.lastNameOf(store.db);
    final full = '$first $last'.trim();
    if (full.isNotEmpty) return full;
    final nick = ChatAuthService(store.db).nickname;
    return nick.isNotEmpty ? nick : tr('Вы');
  }

  void _start(AppDataStore store) {
    final fmt = _fmt;
    if (fmt == null) return;
    // Недостающие записи диктора для участников готовим в фоне (если они уже есть — ничего не делается).
    VoicePacks.ensureNames(store.db, [_myName(store), for (final o in _opps) o.name]);
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
      FinalCompetitor('me', _myName(store), isUser: true),
      for (var i = 0; i < 7; i++) FinalCompetitor('b$i', '${_opps[i].name} (Bot)'),
    ];
    final controller = FinalRunController(
      format: fmt,
      face: face,
      engine: FinalEngine(fmt, competitors),
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
    final champ = await showGlassSheet<Map<String, dynamic>>(
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
    final slot = await showGlassDialog<int>(
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
    final oldChampName = _opps[slot].name;
    setState(() => _opps[slot] = _Opp('${champ['display_name']}',
        stats: ShotStats(n('mx'), n('my'), n('sx'), n('sy'), (st['n'] as num).toInt())));
    if (mounted) VoicePacks.onOpponentRenamed(context.read<AppDataStore>().db, oldName: oldChampName, newName: '${champ['display_name']}');
  }

  Widget _stepper(String label, int value, int min, int max, void Function(int) set, {int step = 1}) => Row(children: [
        Expanded(child: Text(label)),
        IconButton(
          icon: const Icon(Icons.remove_circle_outline),
          onPressed: value - step < min ? null : () => setState(() => set(value - step)),
        ),
        SizedBox(width: 40, child: Text('$value', textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.w700))),
        IconButton(
          icon: const Icon(Icons.add_circle_outline),
          onPressed: value + step > max ? null : () => setState(() => set(value + step)),
        ),
      ]);

  /// Переименование соперника (удержание на строке).
  Future<void> _rename(int i) async {
    final ctl = TextEditingController(text: _opps[i].name);
    final name = await showGlassDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('Имя соперника')),
        content: TextField(controller: ctl, autofocus: true, textCapitalization: TextCapitalization.words),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('Отмена'))),
          TextButton(onPressed: () => Navigator.pop(ctx, ctl.text.trim()), child: Text(tr('Сохранить'))),
        ],
      ),
    );
    ctl.dispose();
    if (name == null || name.isEmpty) return;
    final old = _opps[i].name;
    setState(() => _opps[i] = _Opp(name, stats: _opps[i].stats));
    // Имя бота изменено: старые записи диктора удаляются, фразы с новым именем озвучиваются заново.
    if (mounted) VoicePacks.onOpponentRenamed(context.read<AppDataStore>().db, oldName: old, newName: name);
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
      body: AppBackdrop(kind: 'finals', child: Column(
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
                    Text(f.id == 'rifle_3p_50m' ? tr('По правилам ISSF (п. 6.17.3)') : tr('По правилам ISSF (п. 6.17.2)'), style: theme.textTheme.titleSmall),
                    const SizedBox(height: 6),
                    Text(
                      f.id == 'rifle_3p_50m'
                          ? tr('Подготовка и пристрелка 5 минут. С колена 3 серии по 5 выстрелов (по 200 с), смена и пристрелка 7 минут, лёжа 3 серии по 5 (по 150 с), смена и пристрелка 9 минут, стоя 2 серии по 5 (по 250 с). После 40-го выстрела выбывают двое, дальше 5 одиночных по 50 с: после каждого выбывает самый слабый. Десятые доли, всего 45 выстрелов.')
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
                const SizedBox(height: 6),
                Text(switch (_level) {
                  'easy' => tr('Лёгкие: стреляют чуть хуже вас — средняя точка дальше от центра, разброс больше.'),
                  'medium' => tr('Средние: стреляют как вы — по вашей манере и разбросу.'),
                  'hard' => tr('Сложные: стреляют чуть лучше вас — точка ближе к центру, разброс меньше.'),
                  'unpredictable' => tr('Непредсказуемые: в каждом финале у бота случайный «день» — то лучше, то хуже вас, с колебаниями по ходу.'),
                  _ => tr('Боты разной силы: от чуть слабее вас до чуть сильнее.'),
                }, style: theme.textTheme.bodySmall),
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
                    onLongPress: () => _rename(i),
                    trailing: _opps[i].stats == null
                        ? null
                        : IconButton(
                            icon: const Icon(Icons.close, size: 18),
                            tooltip: tr('Вернуть простого бота'),
                            onPressed: () => setState(() => _opps[i] = _Opp(_names[i])),
                          ),
                  ),
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Text(tr('Удержите соперника, чтобы изменить имя'), style: theme.textTheme.bodySmall),
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
                if (_custom) ...[
                  _stepper(tr('Серий'), _cSeries, 0, 4, (v) => _cSeries = v),
                  _stepper(tr('Выстрелов в серии'), _cPerSeries, 1, 10, (v) => _cPerSeries = v),
                  _stepper(tr('Одиночных выстрелов'), _cSingles, 0, 40, (v) => _cSingles = v),
                  _stepper(tr('Секунд на серию'), _cSeriesSec, 30, 600, (v) => _cSeriesSec = v, step: 10),
                  _stepper(tr('Секунд на выстрел'), _cSingleSec, 10, 120, (v) => _cSingleSec = v, step: 5),
                  _stepper(tr('Выбывание после каждых N выстрелов'), _cStep, 1, 5, (v) => _cStep = v),
                  if (_fmt == null)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(tr('Мало выстрелов: нужно минимум {n}, чтобы выбыли шестеро из восьми', {'n': 6 * _cStep + 1}),
                          style: TextStyle(color: cs.error)),
                    ),
                ],
                const SizedBox(height: 18),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(tr('Озвучка рейтингов')),
                  subtitle: Text(tr('Диктор голосом телефона после каждой серии и выстрела')),
                  value: _voice,
                  onChanged: (v) {
                    setState(() => _voice = v);
                    FinalsPrefs.setVoice(store.db, v);
                  },
                ),
                if (_voice)
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(tr('Озвучка у всех участников')),
                    subtitle: Text(tr('Выключено: говорит только ведущий (если он стреляет — главный из жюри)')),
                    value: _voiceAll,
                    onChanged: (v) {
                      setState(() => _voiceAll = v);
                      FinalsPrefs.setVoiceAll(store.db, v);
                    },
                  ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.record_voice_over_outlined),
                  title: Text(tr('Голос ИИ')),
                  subtitle: Text(tr('Озвучка моделью ИИ: нужен свой ключ в настройках ИИ')),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => FinalsVoiceSettingsScreen(db: store.db))),
                ),
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
                  onPressed: _fmt == null ? null : () => _start(store),
                  icon: const Icon(Icons.play_arrow),
                  label: Text(tr('Начать финал')),
                ),
              ),
            ),
          ),
        ],
      )),
    );
  }
}

class _Opp {
  final String name;
  final ShotStats? stats; // null — обычный бот по вашим тренировкам
  _Opp(this.name, {this.stats});
}

extension on _FinalsScreenState {
  Future<void> _hostFinal(BuildContext context) async {
    final f = await showGlassSheet<FinalFormat>(
      context: context,
      builder: (ctx) => ListView(children: [
        for (final f in FinalFormat.all) ListTile(title: Text(tr(f.nameKey)), onTap: () => Navigator.pop(ctx, f)),
      ]),
    );
    if (f == null || !context.mounted) return;
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => FinalsLobbyScreen(format: f)));
  }
}

/// Приглашения в чужие финалы и вход в идущие.
class _Invites extends StatefulWidget {
  final AppDataStore store;
  const _Invites({required this.store});

  @override
  State<_Invites> createState() => _InvitesState();
}

class _InvitesState extends State<_Invites> {
  List<FinalsInvite> _list = [];

  @override
  void initState() {
    super.initState();
    _list = FinalsInviteStore.pending(widget.store.db);
  }

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      for (final i in _list)
        Card(
          child: ListTile(
            leading: const Icon(Icons.mail_outline),
            title: Text(tr('Приглашение в финал')),
            subtitle: Text(switch (i.role) {
              FinalsRole.athlete => tr('Вы — финалист'),
              FinalsRole.helper => tr('Вы — помощник'),
              FinalsRole.coach => tr('Вы — жюри'),
            }),
            trailing: FilledButton(
              onPressed: () async {
                await joinFinal(context, widget.store, i);
                if (mounted) setState(() => _list = FinalsInviteStore.pending(widget.store.db));
              },
              child: Text(tr('Войти')),
            ),
          ),
        ),
      ListTile(
        contentPadding: EdgeInsets.zero,
        leading: const Icon(Icons.vpn_key_outlined),
        title: Text(tr('Войти по коду приглашения')),
        onTap: () => enterFinalByCode(context, widget.store),
      ),
    ]);
  }
}
