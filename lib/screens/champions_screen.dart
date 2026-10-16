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
    final page = await _svc.champions(_fmt, q: _q, offset: more ? _rows.length : 0);
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
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: GlassHeader(title: Text(tr('Чемпионы'), style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600))),
      body: _loading
          ? const AppLoader()
          : ListView(
              padding: EdgeInsets.fromLTRB(16, MediaQuery.paddingOf(context).top + GlassHeader.height + 8, 16, 24),
              children: [
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
                Text(tr('Упражнение'), style: theme.textTheme.titleSmall),
                const SizedBox(height: 8),
                Wrap(spacing: 8, runSpacing: 8, children: [
                  for (final f in FinalFormat.all)
                    ChoiceChip(
                      label: Text(tr(f.nameKey)),
                      selected: _fmt == f.id,
                      onSelected: (_) {
                        _fmt = f.id;
                        _loadChamps();
                      },
                    ),
                ]),
                const SizedBox(height: 8),
                TextField(
                  decoration: InputDecoration(prefixIcon: const Icon(Icons.search), hintText: tr('Поиск по имени')),
                  onSubmitted: (v) {
                    _q = v;
                    _loadChamps();
                  },
                ),
                const SizedBox(height: 8),
                if (_rows.isEmpty && !_busy) Padding(padding: const EdgeInsets.all(12), child: Text(tr('Пока никого'))),
                for (var i = 0; i < _rows.length; i++)
                  ListTile(
                    dense: true,
                    onTap: () => _openProtocol(_rows[i], i + 1),
                    leading: SizedBox(width: 28, child: Text('${i + 1}', style: const TextStyle(fontWeight: FontWeight.w700))),
                    title: Text('${_rows[i]['display_name']}'),
                    subtitle: ((_rows[i]['flag_count'] as int?) ?? 0) > 0 ? Text(tr('Жалоб: {n}', {'n': _rows[i]['flag_count']})) : null,
                    trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                      Text((_rows[i]['total'] as num).toStringAsFixed(1), style: const TextStyle(fontWeight: FontWeight.w800)),
                      IconButton(
                        tooltip: tr('Пожаловаться'),
                        icon: const Icon(Icons.flag_outlined, size: 20),
                        onPressed: () => _report(_rows[i]),
                      ),
                    ]),
                  ),
                if (_busy) const Center(child: Padding(padding: EdgeInsets.all(12), child: CircularProgressIndicator())),
                if (_more && !_busy) TextButton(onPressed: () => _loadChamps(more: true), child: Text(tr('Показать ещё'))),
              ],
            ),
    );
  }
}
