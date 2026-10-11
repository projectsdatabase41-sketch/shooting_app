import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../finals/champions_service.dart';
import '../finals/final_engine.dart';
import '../i18n/i18n.dart';
import '../services/chat_auth_service.dart';
import '../services/coach_access_service.dart';
import '../state/app_data_store.dart';
import '../widgets/glass_pill.dart';

/// Чемпионы по формату и (для тренера) записи, ждущие подписи.
class ChampionsScreen extends StatefulWidget {
  const ChampionsScreen({super.key});

  @override
  State<ChampionsScreen> createState() => _ChampionsScreenState();
}

class _ChampionsScreenState extends State<ChampionsScreen> {
  late final ChampionsService _svc;
  List<Map<String, dynamic>> _pending = [];
  final Map<String, List<Map<String, dynamic>>> _champs = {};
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
    for (final f in FinalFormat.all) {
      _champs[f.id] = await _svc.champions(f.id);
    }
    if (mounted) {
      setState(() {
        _pending = pending;
        _myAthletes = mine;
        _loading = false;
      });
    }
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: GlassHeader(title: Text(tr('Чемпионы'), style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600))),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
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
                for (final f in FinalFormat.all) ...[
                  Text(tr(f.nameKey), style: theme.textTheme.titleSmall),
                  if ((_champs[f.id] ?? []).isEmpty)
                    Padding(padding: const EdgeInsets.all(12), child: Text(tr('Пока никого'))),
                  for (final r in _champs[f.id] ?? [])
                    ListTile(
                      dense: true,
                      title: Text('${r['display_name']}'),
                      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                        Text((r['total'] as num).toStringAsFixed(1), style: const TextStyle(fontWeight: FontWeight.w800)),
                        IconButton(
                          tooltip: tr('Пожаловаться'),
                          icon: const Icon(Icons.flag_outlined, size: 20),
                          onPressed: () => _report(r),
                        ),
                      ]),
                    ),
                  const SizedBox(height: 12),
                ],
              ],
            ),
    );
  }
}
