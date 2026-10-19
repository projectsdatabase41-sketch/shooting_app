import '../widgets/app_loader.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../i18n/i18n.dart';
import '../models/ai_memory_summary.dart';
import '../services/ai_memory_service.dart';
import '../services/supabase_auth_service.dart';
import '../state/app_data_store.dart';
import '../widgets/empty_state.dart';
import '../widgets/glass_pill.dart';

/// «Память ассистента»: короткие пересказы прошлых разговоров, которые он
/// помнит (хранятся в вашей базе). Можно прочитать, удалить одну запись или
/// стереть всё.
class AiMemoryScreen extends StatefulWidget {
  const AiMemoryScreen({super.key});

  @override
  State<AiMemoryScreen> createState() => _AiMemoryScreenState();
}

class _AiMemoryScreenState extends State<AiMemoryScreen> {
  late final SupabaseAuthService _auth = SupabaseAuthService(context.read<AppDataStore>().db);
  late final AiMemoryService _svc = AiMemoryService(_auth);
  List<AiMemorySummary>? _items;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final l = _auth.isSignedIn ? await _svc.listAll() : <AiMemorySummary>[];
    if (mounted) setState(() => _items = l);
  }

  Future<void> _delete(AiMemorySummary m) async {
    if (m.id == null) return;
    setState(() => _busy = true);
    final ok = await _svc.deleteOne(m.id!);
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) {
      setState(() => _items = [for (final x in _items ?? const <AiMemorySummary>[]) if (x.id != m.id) x]);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('Не удалось удалить'))));
    }
  }

  /// Сброс пересказов прошлых разговоров в вашей базе.
  Future<void> _reset() async {
    final what = tr('память ИИ (пересказы прошлых разговоров)');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('Сбросить память ИИ?')),
        content: Text(tr('Будет сброшена {w}. Тренировки и данные приложения останутся.', {'w': what})),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('Отмена'))),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: Text(tr('Сбросить'))),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _busy = true);
    final done = await _svc.clearAll();
    if (!mounted) return;
    setState(() => _busy = false);
    if (done) {
      setState(() => _items = []);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('Память сброшена'))));
    } else {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('Не удалось стереть'))));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final df = DateFormat('dd.MM.yy HH:mm');
    final items = _items;
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: GlassHeader(
        title: Text(tr('Память ассистента'), style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
        actions: [
          IconButton(
            tooltip: tr('Сбросить память ИИ'),
            icon: const Icon(Icons.delete_sweep_outlined),
            onPressed: _busy ? null : _reset,
            ),
        ],
      ),
      body: items == null
          ? const AppLoader()
          : !_auth.isSignedIn
              ? EmptyState(icon: Icons.cloud_off_outlined, text: tr('Память хранится в вашей базе: войдите в неё в «Данные и синхронизация»'))
              : items.isEmpty
                  ? EmptyState(icon: Icons.psychology_outlined, text: tr('Ассистент пока ничего не запомнил'))
                  : ListView.separated(
                      padding: EdgeInsets.fromLTRB(12, MediaQuery.paddingOf(context).top + GlassHeader.height + 8, 12, 24),
                      itemCount: items.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 6),
                      itemBuilder: (context, i) {
                        final m = items[i];
                        return Card(
                          child: ListTile(
                            title: Text(m.summary.isEmpty ? tr('(без текста)') : m.summary),
                            subtitle: Text(df.format(m.periodStart.toLocal())),
                            trailing: IconButton(
                              tooltip: tr('Удалить'),
                              icon: const Icon(Icons.close),
                              onPressed: _busy ? null : () => _delete(m),
                            ),
                          ),
                        );
                      },
                    ),
    );
  }
}
