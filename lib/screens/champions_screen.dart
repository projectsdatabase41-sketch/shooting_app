import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../finals/champions_service.dart';
import '../finals/final_engine.dart';
import '../i18n/i18n.dart';
import '../services/chat_auth_service.dart';
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

  @override
  void initState() {
    super.initState();
    _svc = ChampionsService(ChatAuthService(context.read<AppDataStore>().db));
    _load();
  }

  Future<void> _load() async {
    final pending = await _svc.pendingForMe();
    for (final f in FinalFormat.all) {
      _champs[f.id] = await _svc.champions(f.id);
    }
    if (mounted) {
      setState(() {
        _pending = pending;
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
                        trailing: FilledButton(onPressed: () => _sign(r), child: Text(tr('Подписать'))),
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
                      trailing: Text((r['total'] as num).toStringAsFixed(1), style: const TextStyle(fontWeight: FontWeight.w800)),
                    ),
                  const SizedBox(height: 12),
                ],
              ],
            ),
    );
  }
}
