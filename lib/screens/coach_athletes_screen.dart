import '../widgets/glass_route.dart';
import 'package:flutter/material.dart';
import 'settings_screen.dart' show inviteAthleteViaMessenger;
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';

import '../services/coach_access_service.dart';
import '../state/app_data_store.dart';
import '../widgets/empty_state.dart';
import '../widgets/glass_pill.dart';
import 'coach_athletes_chat_screen.dart';
import 'coach_diary_screen.dart';
import 'athlete_insights.dart';
import '../logic/friendly_error.dart' show friendlyErrorDevMode;
import '../i18n/i18n.dart';

/// Список подключённых спортсменов у тренера (мульти-спортсменский
/// режим — решение пользователя: "как список создания упражнений, так
/// же создание подключений к спортсменам"). Тап — открыть дневник
/// этого спортсмена; "+" внизу слева — добавить нового, как у
/// спортсмена при создании упражнения.
///
/// Сетка в два столбца, кнопки квадратные (решение пользователя).
/// Перетаскивание сделано на встроенных `LongPressDraggable`/
/// `DragTarget` — без отдельного пакета под двухколоночную сетку с
/// "прилипанием к пальцу". Долгое нажатие БЕЗ движения — это тоже
/// перетаскивание, которое заканчивается на той же самой
/// ячейке: там это ловится как частный случай "перетащили сами на
/// себя" и открывает настройки спортсмена, а не меняет порядок
/// (решение пользователя: "удержал и отпустил, позиция не изменилась —
/// открыть настройки"). Перетаскивание на ДРУГУЮ ячейку меняет
/// спортсменов местами.
class CoachAthletesScreen extends StatefulWidget {
  const CoachAthletesScreen({super.key});

  @override
  State<CoachAthletesScreen> createState() => _CoachAthletesScreenState();
}

class _CoachAthletesScreenState extends State<CoachAthletesScreen> {
  late final CoachAccessService _access;
  late List<CoachAthlete> _athletes;

  // Режим разработчика: сводка, группы, поиск, архив, план, сравнение.
  final Map<String, AthleteStats> _stats = {};
  final Map<String, AthleteMeta> _meta = {};
  String _query = '';
  String? _groupFilter;
  bool _showArchived = false;
  bool _loadingStats = false;

  AthleteMeta _metaOf(CoachAthlete a) => _meta.putIfAbsent(a.id, () => AthleteMeta.load(context.read<AppDataStore>().db, a.id));

  List<CoachAthlete> get _visible {
    if (!friendlyErrorDevMode) return _athletes;
    final q = _query.trim().toLowerCase();
    return [
      for (final a in _athletes)
        if ((_showArchived || !_metaOf(a).archived) &&
            (_groupFilter == null || _metaOf(a).group == _groupFilter) &&
            (q.isEmpty || a.name.toLowerCase().contains(q)))
          a,
    ];
  }

  Future<void> _loadAllStats() async {
    if (_loadingStats) return;
    setState(() => _loadingStats = true);
    for (final a in _visible) {
      try {
        final s = await loadAthleteStats(_access, a, recent: 1);
        if (mounted) setState(() => _stats[a.id] = s);
      } catch (_) {}
    }
    if (mounted) setState(() => _loadingStats = false);
  }

  Future<void> _compare() async {
    final chosen = <String>{};
    final picked = await showGlassDialog<List<CoachAthlete>>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          title: Text(tr('Сравнить спортсменов')),
          content: SizedBox(
            width: double.maxFinite,
            child: ListView(shrinkWrap: true, children: [
              for (final a in _athletes)
                CheckboxListTile(
                  dense: true,
                  value: chosen.contains(a.id),
                  title: Text(a.name),
                  onChanged: (v) => setS(() => v == true ? chosen.add(a.id) : chosen.remove(a.id)),
                ),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(ctx).pop(), child: Text(tr('Отмена'))),
            FilledButton(
              onPressed: chosen.length < 2 ? null : () => Navigator.of(ctx).pop([for (final a in _athletes) if (chosen.contains(a.id)) a]),
              child: Text(tr('Сравнить')),
            ),
          ],
        ),
      ),
    );
    if (picked == null || !mounted) return;
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => AthleteCompareScreen(access: _access, athletes: picked)));
  }

  void _openInfo(CoachAthlete a) {
    final db = context.read<AppDataStore>().db;
    showAthleteSheet(
      context,
      db: db,
      athlete: a,
      meta: _metaOf(a),
      stats: _stats[a.id],
      reload: () async {
        final s = await loadAthleteStats(_access, a);
        _stats[a.id] = s;
        return s;
      },
      changed: () {
        if (mounted) setState(() {});
      },
    );
  }

  Widget _filterBar() {
    final groups = {for (final a in _athletes) _metaOf(a).group}..remove('');
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Column(children: [
        TextField(
          onChanged: (v) => setState(() => _query = v),
          decoration: InputDecoration(prefixIcon: const Icon(Icons.search), hintText: tr('Поиск по имени'), isDense: true),
        ),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(children: [
            for (final g in groups)
              Padding(
                padding: const EdgeInsets.only(right: 6, top: 6),
                child: FilterChip(label: Text(g), selected: _groupFilter == g, onSelected: (v) => setState(() => _groupFilter = v ? g : null)),
              ),
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: FilterChip(label: Text(tr('Архив')), selected: _showArchived, onSelected: (v) => setState(() => _showArchived = v)),
            ),
          ]),
        ),
      ]),
    );
  }

  @override
  void initState() {
    super.initState();
    _access = CoachAccessService(context.read<AppDataStore>().db);
    _athletes = _access.listAthletes();
  }

  void _refresh() => setState(() => _athletes = _access.listAthletes());

  Future<void> _openAthleteDialog({CoachAthlete? existing}) async {
    final nameCtrl = TextEditingController(text: existing?.name ?? '');
    final urlCtrl = TextEditingController(text: existing?.url ?? '');
    final keyCtrl = TextEditingController(text: existing?.anonKey ?? '');
    final tokenCtrl = TextEditingController(text: existing?.token ?? '');
    final result = await showGlassDialog<_AthleteDialogResult>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(existing == null ? tr('Новый спортсмен') : tr('Спортсмен')),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameCtrl,
                autofocus: true,
                decoration: InputDecoration(labelText: tr('Имя спортсмена')),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: urlCtrl,
                decoration: InputDecoration(
                  labelText: tr('Адрес базы'),
                  hintText: 'https://xxxx.supabase.co',
                ),
                keyboardType: TextInputType.url,
                autocorrect: false,
              ),
              const SizedBox(height: 10),
              TextField(
                controller: keyCtrl,
                decoration: InputDecoration(labelText: tr('Публичный ключ (anon)')),
                obscureText: true,
                autocorrect: false,
              ),
              const SizedBox(height: 10),
              TextField(
                controller: tokenCtrl,
                decoration: InputDecoration(labelText: tr('Токен доступа')),
                obscureText: true,
                autocorrect: false,
              ),
            ],
          ),
        ),
        actions: [
          if (existing != null)
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(const _AthleteDialogResult.delete()),
              child: Text(tr('Удалить'), style: TextStyle(color: Theme.of(ctx).colorScheme.error)),
            ),
          TextButton(onPressed: () => Navigator.of(ctx).pop(), child: Text(tr('Отмена'))),
          FilledButton(
            onPressed: () {
              if (nameCtrl.text.trim().isEmpty ||
                  urlCtrl.text.trim().isEmpty ||
                  keyCtrl.text.trim().isEmpty ||
                  tokenCtrl.text.trim().isEmpty) {
                return;
              }
              Navigator.of(ctx).pop(_AthleteDialogResult.save(CoachAthlete(
                id: existing?.id ?? const Uuid().v4(),
                name: nameCtrl.text,
                url: urlCtrl.text,
                anonKey: keyCtrl.text,
                token: tokenCtrl.text,
              )));
            },
            child: Text(tr('Сохранить')),
          ),
        ],
      ),
    );
    if (result == null) return;
    if (result.delete && existing != null) {
      _access.deleteAthlete(existing.id);
    } else if (result.athlete != null) {
      _access.saveAthlete(result.athlete!);
    }
    _refresh();
  }

  void _openDiary(CoachAthlete athlete) {
    _access.selectAthlete(athlete);
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => CoachDiaryScreen(athleteName: athlete.name),
    ));
  }

  /// Перетащили одного спортсмена на ячейку другого — меняются местами
  /// (простой swap, а не вставка со сдвигом остальных: для сетки это
  /// понятнее — карточка всегда попадает ровно туда, куда её положили).
  void _swap(String draggedId, String targetId) {
    if (draggedId == targetId) return;
    final di = _athletes.indexWhere((a) => a.id == draggedId);
    final ti = _athletes.indexWhere((a) => a.id == targetId);
    if (di < 0 || ti < 0) return;
    setState(() {
      final tmp = _athletes[di];
      _athletes[di] = _athletes[ti];
      _athletes[ti] = tmp;
    });
    _access.reorderAthletes([for (final a in _athletes) a.id]);
  }

  @override
  Widget build(BuildContext context) {
    final topInset = MediaQuery.paddingOf(context).top;
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: GlassHeader(
        title: Text(tr('Спортсмены'), style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
        actions: [
          if (friendlyErrorDevMode && _athletes.isNotEmpty) ...[
            GlassCircleButton(
              icon: _loadingStats ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const BoldIcon(Icons.refresh),
              tooltip: tr('Обновить сводку'),
              onTap: _loadingStats ? null : _loadAllStats,
            ),
            const SizedBox(width: 6),
            if (_athletes.length > 1) GlassCircleButton(icon: const BoldIcon(Icons.compare_arrows), tooltip: tr('Сравнить спортсменов'), onTap: _compare),
          ],
        ],
      ),
      body: _athletes.isEmpty
          ? ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: EdgeInsets.only(top: topInset + GlassHeader.height),
              children: [
                EmptyState(
                  icon: Icons.groups_outlined,
                  text: tr('Пока никого не подключили — нажмите "+", чтобы добавить спортсмена.'),
                ),
              ],
            )
          : Column(children: [
              SizedBox(height: topInset + GlassHeader.height),
              if (friendlyErrorDevMode) _filterBar(),
              Expanded(
                child: GridView.builder(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 80),
              // Компактные плитки: на телефоне три в ряд.
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 128,
                mainAxisSpacing: 10,
                crossAxisSpacing: 10,
                childAspectRatio: 1,
              ),
              // Первая плитка — «Чат» со спортсменами, дальше сами спортсмены.
              itemCount: _visible.length + 1,
              itemBuilder: (context, i) {
                if (i == 0) {
                  return Card(
                    child: InkWell(
                      borderRadius: BorderRadius.circular(12),
                      onTap: () => Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) => CoachAthletesChatScreen(access: _access),
                      )),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.forum_outlined, size: 24, color: Theme.of(context).colorScheme.primary),
                          const SizedBox(height: 6),
                          Text(tr('Чат'), style: Theme.of(context).textTheme.titleSmall),
                        ],
                      ),
                    ),
                  );
                }
                final athlete = _visible[i - 1];
                final st = friendlyErrorDevMode ? _stats[athlete.id] : null;
                return _AthleteCell(
                  key: ValueKey(athlete.id),
                  athlete: athlete,
                  onTap: () => _openDiary(athlete),
                  onSettings: () => _openAthleteDialog(existing: athlete),
                  onDropped: (draggedId) => _swap(draggedId, athlete.id),
                  dev: friendlyErrorDevMode,
                  statusColor: st == null
                      ? null
                      : switch (st.status) {
                          ShareTokenStatus.valid => Colors.green,
                          ShareTokenStatus.revoked => Colors.red,
                          _ => Colors.grey,
                        },
                  caption: st == null || st.status != ShareTokenStatus.valid ? null : (st.daysSince == null ? '—' : (st.daysSince! <= 0 ? tr('сегодня') : tr('{n} дн.', {'n': st.daysSince}))),
                  stale: st != null && st.status == ShareTokenStatus.valid && (st.daysSince ?? 99) >= 7,
                  onInfo: () => _openInfo(athlete),
                );
              },
            ),
              ),
            ]),
      // Справа внизу — как «новая запись» в дневнике (единообразие).
      floatingActionButton: FloatingActionButton(
        tooltip: tr('Добавить спортсмена'),
        onPressed: () async {
          final how = await showGlassSheet<String>(
            context: context,
            builder: (ctx) => SafeArea(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                ListTile(
                  leading: const Icon(Icons.forum_outlined),
                  title: Text(tr('Пригласить из мессенджера')),
                  subtitle: Text(tr('Спортсмену придёт приглашение — без кодов и токенов')),
                  onTap: () => Navigator.pop(ctx, 'invite'),
                ),
                ListTile(
                  leading: const Icon(Icons.key_outlined),
                  title: Text(tr('Вручную (адрес и токен)')),
                  onTap: () => Navigator.pop(ctx, 'manual'),
                ),
              ]),
            ),
          );
          if (!mounted || how == null) return;
          if (how == 'invite') {
            await inviteAthleteViaMessenger(context, context.read<AppDataStore>());
          } else {
            _openAthleteDialog();
          }
        },
        child: const Icon(Icons.add),
      ),
    );
  }
}

/// Одна квадратная кнопка спортсмена в сетке — тап открывает дневник,
/// долгое нажатие-и-отпускание НА МЕСТЕ открывает настройки (см.
/// объяснение у класса экрана), перетаскивание на другую ячейку меняет
/// спортсменов местами.
class _AthleteCell extends StatelessWidget {
  final CoachAthlete athlete;
  final VoidCallback onTap;
  final VoidCallback onSettings;
  final void Function(String draggedAthleteId) onDropped;

  // Режим разработчика: состояние доступа, давность последней тренировки, карточка.
  final bool dev;
  final Color? statusColor;
  final String? caption;
  final bool stale;
  final VoidCallback? onInfo;

  const _AthleteCell({
    super.key,
    required this.athlete,
    required this.onTap,
    required this.onSettings,
    required this.onDropped,
    this.dev = false,
    this.statusColor,
    this.caption,
    this.stale = false,
    this.onInfo,
  });

  Widget _card(BuildContext context) => Card(
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: Stack(children: [
            if (dev && statusColor != null) Positioned(left: 8, top: 8, child: Icon(Icons.circle, size: 9, color: statusColor)),
            if (dev && onInfo != null)
              Positioned(
                right: 0,
                top: 0,
                child: IconButton(visualDensity: VisualDensity.compact, iconSize: 18, onPressed: onInfo, icon: const Icon(Icons.info_outline)),
              ),
            Positioned.fill(child: Padding(
            padding: const EdgeInsets.all(8),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.person_outline, size: 24),
                const SizedBox(height: 6),
                Text(
                  athlete.name,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                if (dev && caption != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(caption!, style: Theme.of(context).textTheme.labelSmall?.copyWith(color: stale ? Colors.orange : null, fontWeight: stale ? FontWeight.w700 : null)),
                  ),
              ],
            ),
          )),
          ]),
        ),
      );

  @override
  Widget build(BuildContext context) {
    return DragTarget<String>(
      onAcceptWithDetails: (details) {
        if (details.data == athlete.id) {
          onSettings();
        } else {
          onDropped(details.data);
        }
      },
      builder: (context, candidateData, rejectedData) => LongPressDraggable<String>(
        data: athlete.id,
        feedback: Material(
          elevation: 4,
          borderRadius: BorderRadius.circular(12),
          child: SizedBox(width: 110, height: 110, child: _card(context)),
        ),
        childWhenDragging: Opacity(opacity: 0.3, child: _card(context)),
        child: _card(context),
      ),
    );
  }
}

class _AthleteDialogResult {
  final CoachAthlete? athlete;
  final bool delete;
  const _AthleteDialogResult.save(this.athlete) : delete = false;
  const _AthleteDialogResult.delete()
      : athlete = null,
        delete = true;
}
