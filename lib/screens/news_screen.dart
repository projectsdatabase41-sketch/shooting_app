import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../i18n/i18n.dart';
import '../services/chat_translation_service.dart';
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

  /// Автоперевод заголовков на язык системы: кэш по ссылке новости.
  final Map<String, String> _translated = {};

  static bool _hasCyrillic(String s) => RegExp(r'[а-яА-ЯёЁ]').hasMatch(s);

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
    _translateVisible(db);
  }

  /// Переводим первые заголовки на язык системы (как в чате). Ошибки и
  /// лимиты переводчика не мешают: показываем оригинал.
  Future<void> _translateVisible(dynamic db) async {
    final service = ChatTranslationService();
    var done = 0;
    for (final n in NewsService.items) {
      if (done >= 10) break;
      if (_translated.containsKey(n.link)) continue;
      if (_hasCyrillic(n.title)) continue;
      try {
        final t = await service.translateIfNeeded(n.title, targetLanguage: '');
        if (t != null && t.isNotEmpty) {
          _translated[n.link] = t;
          done++;
          if (mounted) setState(() {});
        }
      } catch (_) {
        break; // лимит переводчика — не долбим дальше
      }
    }
  }

  /// Краткая карточка новости: заголовок, описание и источник внизу.
  Future<void> _showDetails(NewsItem n) async {
    final theme = Theme.of(context);
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (n.image.isNotEmpty) ...[
                ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Image.network(
                    n.image,
                    height: 160,
                    width: double.infinity,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                  ),
                ),
                const SizedBox(height: 12),
              ],
              Text(_translated[n.link] ?? n.title,
                  style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
              if (n.summary.isNotEmpty) ...[
                const SizedBox(height: 10),
                Text(n.summary, style: theme.textTheme.bodyMedium),
              ],
              const SizedBox(height: 14),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '${n.source}${n.date.isEmpty ? '' : ' · ${n.date.substring(0, n.date.length > 10 ? 10 : n.date.length)}'}',
                      style: theme.textTheme.labelSmall,
                    ),
                  ),
                  TextButton.icon(
                    onPressed: () {
                      Navigator.of(ctx).pop();
                      _open(n.link);
                    },
                    icon: const Icon(Icons.open_in_new, size: 18),
                    label: Text(tr('К источнику')),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
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
                  final title = _translated[n.link] ?? n.title;
                  return ListTile(
                    leading: n.image.isEmpty
                        ? null
                        : ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: Image.network(
                              n.image,
                              width: 56,
                              height: 56,
                              fit: BoxFit.cover,
                              errorBuilder: (_, __, ___) => const SizedBox(
                                width: 56,
                                height: 56,
                                child: Icon(Icons.newspaper_outlined, size: 22),
                              ),
                            ),
                          ),
                    title: Text(title, maxLines: 3, overflow: TextOverflow.ellipsis),
                    subtitle: Text('${n.source}${date.isEmpty ? '' : ' · $date'}',
                        style: theme.textTheme.labelSmall),
                    // Ссылки справа нет: по нажатию открываем краткую сводку,
                    // а источник уже внизу карточки (отзыв 19.11).
                    onTap: () => _showDetails(n),
                  );
                },
              ),
      ),
    );
  }
}
