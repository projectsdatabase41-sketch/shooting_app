import '../widgets/app_loader.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../finals/champions_service.dart';
import '../finals/final_engine.dart';
import '../i18n/i18n.dart';
import '../services/chat_auth_service.dart';
import '../services/coach_access_service.dart';
import '../state/app_data_store.dart';
import '../widgets/glass_pill.dart';
import 'final_run_screen.dart' show FinalResultScreen;

/// Чемпионы по формату и (для тренера) записи, ждущие подписи.
class ChampionsScreen extends StatefulWidget {
  const ChampionsScreen({super.key});

  @override
  State<ChampionsScreen> createState() => _ChampionsScreenState();
}

class _ChampionsScreenState extends State<ChampionsScreen> {
  late final ChampionsService _svc;
  List<Map<String, dynamic>> _pending = [];
  String _fmt = FinalFormat.all.first.id;
  String _q = '';
  int? _year; // фильтр по году публикации
  final _search = TextEditingController();
  List<Map<String, dynamic>> _rows = [];
  bool _more = false;
  bool _busy = false;
  List<Map<String, dynamic>> _banned = [];
  List<Map<String, dynamic>> _appeals = [];
  bool _loading = true;
  Set<String> _myAthletes = {}; // chat-id спортсменов, подключённых к этому тренеру

  @override
  void initState() {
    super.initState();
    _svc = ChampionsService(ChatAuthService(context.read<AppDataStore>().db));
    _load();
  }

  Future<void> _load() async {
    final pending = await _svc.pendingForMe();
    final banned = await _svc.myBanned();
    final appeals = await _svc.appeals();
    final db = context.read<AppDataStore>().db;
    final auth = ChatAuthService(db);
    final access = CoachAccessService(db);
    final mine = <String>{};
    if (pending.isNotEmpty) {
      for (final a in access.listAthletes()) {
        final link = await access.linkChat(a, chatUserId: auth.userId, nickname: auth.nickname);
        if (link != null) mine.add(link.chatUserId);
      }
    }
    await _loadChamps();
    if (mounted) {
      setState(() {
        _pending = pending;
        _banned = banned;
        _appeals = appeals;
        _myAthletes = mine;
        _loading = false;
      });
    }
  }

  /// Загрузка чемпионов выбранного упражнения (с нуля или следующей страницей).
  Future<void> _loadChamps({bool more = false}) async {
    if (_busy) return;
    setState(() => _busy = true);
    final page = await _svc.champions(_fmt, q: _q, offset: more ? _rows.length : 0, year: _year);
    if (!mounted) return;
    setState(() {
      _rows = more ? [..._rows, ...page] : page;
      _more = page.length >= ChampionsService.pageSize;
      _busy = false;
    });
  }

  /// Протокол чемпиона: серии и одиночные выстрелы, как в ведомости.
  void _openProtocol(Map<String, dynamic> r, int place) {
    final shots = ((r['protocol'] as Map?)?['shots'] as List?)?.map((e) => (e as num).toDouble()).toList();
    if (shots == null || shots.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('Подробный протокол этого результата не опубликован'))));
      return;
    }
    final rec = <String, dynamic>{
      'format': r['format_id'],
      'face': '',
      'standings': [
        {'id': 'p', 'name': '${r['display_name']}', 'place': place, 'total': (r['total'] as num).toDouble(), 'user': true},
      ],
      'shots': [for (var i = 0; i < shots.length; i++) {'who': 'p', 'i': i, 's': shots[i]}],
    };
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => FinalResultScreen(record: rec, readOnly: true, title: '${r['display_name']}'),
    ));
  }

  Future<void> _sign(Map<String, dynamic> r) async {
    final err = await _svc.sign(r['id'] as String);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err ?? tr('Подписано'))));
    if (err == null) _load();
  }

  Future<void> _report(Map<String, dynamic> r) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('Пожаловаться на результат?')),
        content: Text(tr('Используйте только если результат нечестный. При нескольких жалобах от разных людей публикация скрывается на 30 дней.')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('Отмена'))),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: Text(tr('Пожаловаться'))),
        ],
      ),
    );
    if (ok != true) return;
    final err = await _svc.report(r['id'] as String);
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err ?? tr('Жалоба отправлена'))));
  }

  Future<void> _act(Future<String?> f, String ok) async {
    final err = await f;
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err ?? ok)));
    if (err == null) _load();
  }

  String _until(Map<String, dynamic> r) {
    final v = '${r['banned_until']}';
    return v.contains('infinity') ? tr('навсегда') : tr('до {d}', {'d': v.substring(0, 10)});
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  /// Люди в порядке лучшего результата: у каждого — лучший старт и число стартов в выборке.
  List<({String userId, String name, double best, int count, Map<String, dynamic> bestRow})> _people() {
    final byUser = <String, List<Map<String, dynamic>>>{};
    for (final r in _rows) {
      byUser.putIfAbsent('${r['user_id'] ?? r['display_name']}', () => []).add(r);
    }
    final out = [
      for (final e in byUser.entries)
        (
          userId: e.key,
          name: '${e.value.first['display_name']}',
          best: (e.value.first['total'] as num).toDouble(), // строки уже по убыванию
          count: e.value.length,
          bestRow: e.value.first,
        )
    ];
    out.sort((a, b) => b.best.compareTo(a.best));
    return out;
  }

  Widget _filters(ThemeData theme) {
    final years = [for (var y = DateTime.now().year; y >= DateTime.now().year - 4; y--) y];
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(tr('Упражнение'), style: theme.textTheme.labelLarge),
      const SizedBox(height: 6),
      SizedBox(
        height: 40,
        child: ListView(scrollDirection: Axis.horizontal, children: [
          for (final f in FinalFormat.all)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ChoiceChip(
                label: Text(tr(f.nameKey)),
                selected: _fmt == f.id,
                onSelected: (_) {
                  _fmt = f.id;
                  _loadChamps();
                },
              ),
            ),
        ]),
      ),
      const SizedBox(height: 8),
      Text(tr('Год'), style: theme.textTheme.labelLarge),
      const SizedBox(height: 6),
      Wrap(spacing: 8, children: [
        ChoiceChip(
          label: Text(tr('Все')),
          selected: _year == null,
          onSelected: (_) {
            _year = null;
            _loadChamps();
          },
        ),
        for (final y in years)
          ChoiceChip(
            label: Text('$y'),
            selected: _year == y,
            onSelected: (_) {
              _year = y;
              _loadChamps();
            },
          ),
      ]),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final people = _people();
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: GlassHeader(title: Text(tr('Чемпионы'), style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600))),
      body: _loading
          ? const AppLoader()
          : ListView(
              padding: EdgeInsets.fromLTRB(16, MediaQuery.paddingOf(context).top + GlassHeader.height + 8, 16, 24),
              children: [
                TextField(
                  controller: _search,
                  textInputAction: TextInputAction.search,
                  decoration: InputDecoration(
                    prefixIcon: const Icon(Icons.search),
                    hintText: tr('Поиск по имени'),
                    suffixIcon: _q.isEmpty
                        ? null
                        : IconButton(
                            icon: const Icon(Icons.close),
                            onPressed: () {
                              _search.clear();
                              _q = '';
                              _loadChamps();
                            },
                          ),
                  ),
                  onSubmitted: (v) {
                    _q = v;
                    _loadChamps();
                  },
                ),
                const SizedBox(height: 12),
                if (_pending.isNotEmpty) ...[
                  Text(tr('Ждут вашей подписи'), style: theme.textTheme.titleSmall),
                  for (final r in _pending)
                    Card(
                      child: ListTile(
                        title: Text('${r['display_name']} · ${(r['total'] as num).toStringAsFixed(1)}'),
                        subtitle: Text(tr(FinalFormat.all.firstWhere((f) => f.id == r['format_id'], orElse: () => FinalFormat.airRifle10m).nameKey)),
                        trailing: _myAthletes.contains(r['user_id'])
                            ? FilledButton(onPressed: () => _sign(r), child: Text(tr('Подписать')))
                            : Text(tr('Не ваш спортсмен'), style: theme.textTheme.bodySmall),
                      ),
                    ),
                  const SizedBox(height: 16),
                ],
                if (_banned.isNotEmpty) ...[
                  Text(tr('Мои скрытые результаты'), style: theme.textTheme.titleSmall),
                  for (final r in _banned)
                    Card(
                      child: ListTile(
                        title: Text('${(r['total'] as num).toStringAsFixed(1)} · ${_until(r)}'),
                        subtitle: Text(tr('Жалоб: {n}', {'n': r['flag_count']})),
                        trailing: r['appeal_requested'] == true
                            ? Text(tr('Апелляция подана'), style: theme.textTheme.bodySmall)
                            : TextButton(onPressed: () => _act(_svc.requestAppeal(r['id'] as String), tr('Апелляция подана')), child: Text(tr('Обжаловать'))),
                      ),
                    ),
                  const SizedBox(height: 16),
                ],
                if (_appeals.isNotEmpty) ...[
                  Text(tr('Апелляции: поддержать возврат?'), style: theme.textTheme.titleSmall),
                  for (final r in _appeals)
                    Card(
                      child: ListTile(
                        title: Text('${r['display_name']} · ${(r['total'] as num).toStringAsFixed(1)}'),
                        subtitle: Text(tr('Жалоб: {n} · {u}', {'n': r['flag_count'], 'u': _until(r)})),
                        trailing: TextButton(onPressed: () => _act(_svc.voteAppeal(r['id'] as String), tr('Голос принят')), child: Text(tr('Вернуть'))),
                      ),
                    ),
                  const SizedBox(height: 16),
                ],
                _filters(theme),
                const SizedBox(height: 12),
                Text(tr('Чемпионы'), style: theme.textTheme.titleSmall),
                const SizedBox(height: 8),
                if (people.isEmpty && !_busy) Padding(padding: const EdgeInsets.all(12), child: Text(tr('Пока никого'))),
                for (var i = 0; i < people.length; i++)
                  Card(
                    margin: const EdgeInsets.only(bottom: 8),
                    child: ListTile(
                      onTap: () => Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) => ChampionProfileScreen(
                          svc: _svc,
                          userId: people[i].userId,
                          name: people[i].name,
                          place: i + 1,
                          onOpenProtocol: _openProtocol,
                          onReport: _report,
                        ),
                      )),
                      leading: CircleAvatar(
                        backgroundColor: i < 3 ? const Color(0xFFD9A441) : theme.colorScheme.surfaceContainerHigh,
                        child: Text('${i + 1}', style: const TextStyle(fontWeight: FontWeight.w800)),
                      ),
                      title: Text(people[i].name, style: const TextStyle(fontWeight: FontWeight.w600)),
                      subtitle: Text(tr('Стартов: {n}', {'n': people[i].count})),
                      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                        Text(people[i].best.toStringAsFixed(1), style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
                        const Icon(Icons.chevron_right),
                      ]),
                    ),
                  ),
                if (_busy) const Center(child: Padding(padding: EdgeInsets.all(12), child: CircularProgressIndicator())),
                if (_more && !_busy) TextButton(onPressed: () => _loadChamps(more: true), child: Text(tr('Показать ещё'))),
              ],
            ),
    );
  }
}


/// Профиль чемпиона: все его опубликованные результаты, лучшие сверху.
/// Нажатие на результат — смета выстрелов (протокол).
class ChampionProfileScreen extends StatefulWidget {
  final ChampionsService svc;
  final String userId;
  final String name;
  final int place;
  final void Function(Map<String, dynamic> row, int place) onOpenProtocol;
  final void Function(Map<String, dynamic> row) onReport;
  const ChampionProfileScreen({
    super.key,
    required this.svc,
    required this.userId,
    required this.name,
    required this.place,
    required this.onOpenProtocol,
    required this.onReport,
  });

  @override
  State<ChampionProfileScreen> createState() => _ChampionProfileScreenState();
}

class _ChampionProfileScreenState extends State<ChampionProfileScreen> {
  List<Map<String, dynamic>>? _rows;

  @override
  void initState() {
    super.initState();
    widget.svc.resultsOf(widget.userId).then((r) {
      if (mounted) setState(() => _rows = r);
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final rows = _rows;
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: GlassHeader(title: Text(widget.name, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600))),
      body: rows == null
          ? const AppLoader()
          : ListView(
              padding: EdgeInsets.fromLTRB(16, MediaQuery.paddingOf(context).top + GlassHeader.height + 8, 16, 24),
              children: [
                if (rows.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(
                      tr('Лучший результат {s} · стартов: {n}', {'s': (rows.first['total'] as num).toStringAsFixed(1), 'n': rows.length}),
                      style: theme.textTheme.bodyMedium,
                    ),
                  ),
                if (rows.isEmpty) Padding(padding: const EdgeInsets.all(12), child: Text(tr('Результатов нет'))),
                for (final r in rows)
                  Card(
                    margin: const EdgeInsets.only(bottom: 8),
                    child: ListTile(
                      onTap: () => widget.onOpenProtocol(r, widget.place),
                      title: Text(tr(FinalFormat.all.firstWhere((f) => f.id == r['format_id'], orElse: () => FinalFormat.airRifle10m).nameKey)),
                      subtitle: Text('${r['created_at']}'.length >= 10 ? '${r['created_at']}'.substring(0, 10) : ''),
                      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                        Text((r['total'] as num).toStringAsFixed(1), style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
                        IconButton(
                          tooltip: tr('Пожаловаться'),
                          icon: const Icon(Icons.flag_outlined, size: 20),
                          onPressed: () => widget.onReport(r),
                        ),
                      ]),
                    ),
                  ),
              ],
            ),
    );
  }
}
