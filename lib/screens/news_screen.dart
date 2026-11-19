import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../i18n/i18n.dart';
import '../services/news_service.dart';
import '../state/app_data_store.dart';
import '../widgets/app_backdrop.dart';
import '../widgets/glass_pill.dart';

/// Новости о стрельбе: лента собирается на сервере (RSS → кэш R2) и приходит
/// готовым списком. При запуске приложение подтягивает её в фоне, поэтому
/// экран открывается сразу и без нагрузки на RSS-источники.
class NewsScreen extends StatefulWidget {
  const NewsScreen({super.key});

  @override
  State<NewsScreen> createState() => _NewsScreenState();
}

class _NewsScreenState extends State<NewsScreen> {
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _reload(force: false);
  }

  Future<void> _reload({required bool force}) async {
    if (_loading) return;
    setState(() => _loading = true);
    final db = context.read<AppDataStore>().db;
    await NewsService.refresh(db: db, force: force);
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _open(String url) async {
    if (url.isEmpty) return;
    try {
      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final items = NewsService.items;
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: GlassHeader(
        title: Text(tr('Новости')),
        actions: [
          IconButton(
            tooltip: tr('Обновить'),
            onPressed: _loading ? null : () => _reload(force: true),
            icon: _loading
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.refresh),
          ),
        ],
      ),
      body: AppBackdrop(
        kind: 'settings',
        child: items.isEmpty
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    tr('Новостей пока нет. Они обновляются на сервере дважды в день — загляните позже.'),
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium,
                  ),
                ),
              )
            : ListView.separated(
                padding: EdgeInsets.fromLTRB(16, MediaQuery.paddingOf(context).top + GlassHeader.height + 12, 16, 32),
                itemCount: items.length,
                separatorBuilder: (_, __) => const Divider(height: 1, thickness: 0.5),
                itemBuilder: (_, i) {
                  final n = items[i];
                  final date = n.date.length > 10 ? n.date.substring(0, 10) : n.date;
                  return ListTile(
                    title: Text(n.title, maxLines: 3, overflow: TextOverflow.ellipsis),
                    subtitle: Text('${n.source}${date.isEmpty ? '' : ' · $date'}',
                        style: theme.textTheme.labelSmall),
                    trailing: const Icon(Icons.open_in_new, size: 18),
                    onTap: () => _open(n.link),
                  );
                },
              ),
      ),
    );
  }
}
