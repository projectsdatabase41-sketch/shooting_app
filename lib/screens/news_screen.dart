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

  /// Геометрия карточки вынесена сюда, чтобы список и шторка не разъезжались.
  /// Скругление 16 и зазор 14 — отзыв владельца 23.11, п.1 («новости лучше
  /// разделить, что-то типа рамок разных»): каждая новость — отдельная карточка.
  static const double _cardRadius = 16;
  static const double _cardGap = 14;
  static const double _cardPad = 12;
  static const EdgeInsets _cardPadding = EdgeInsets.all(_cardPad);

  static bool _hasCyrillic(String s) => RegExp(r'[а-яА-ЯёЁ]').hasMatch(s);

  /// В ленте и в подвале карточки нужна только дата, а сервер отдаёт ISO-время.
  static String _shortDate(String date) =>
      date.length > 10 ? date.substring(0, 10) : date;

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

  /// Шторка с картинкой и кратким текстом — только по долгому нажатию, как
  /// запасной путь. Основной путь тапа — сразу источник (отзыв 23.11, п.3:
  /// «лучше при нажатии сразу открывать источник»).
  ///
  /// Фон задаём явно и непрозрачный: тема в режиме «стекло» отдаёт
  /// modalBackgroundColor полупрозрачным, из-за этого шторка просвечивала и
  /// текст было не прочитать (отзыв 23.11, п.2). barrierColor не трогаем —
  /// нужен затемняющий барьер по умолчанию.
  Future<void> _showDetails(NewsItem n) async {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      backgroundColor: cs.surfaceContainerHighest,
      builder: (ctx) => Material(
        color: cs.surfaceContainerHighest,
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (n.image.isNotEmpty) ...[
                  ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: AspectRatio(
                      aspectRatio: 16 / 9,
                      child: Image.network(
                        n.image,
                        width: double.infinity,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => ColoredBox(
                          color: cs.surfaceContainerHigh,
                          child: Center(
                            child: Icon(Icons.newspaper_outlined,
                                size: 28, color: cs.onSurfaceVariant),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
                Text(
                  _translated[n.link] ?? n.title,
                  style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600, color: cs.onSurface),
                ),
                if (n.summary.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Text(
                    n.summary,
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(color: cs.onSurfaceVariant),
                  ),
                ],
                const SizedBox(height: 14),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '${n.source}${n.date.isEmpty ? '' : ' · ${_shortDate(n.date)}'}',
                        style: theme.textTheme.labelSmall
                            ?.copyWith(color: cs.onSurfaceVariant),
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
      ),
    );
  }

  Future<void> _open(String url) async {
    if (url.isEmpty) return;
    try {
      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    } catch (_) {}
  }

  /// Одна новость отдельной карточкой (отзыв 23.11, п.1): фон
  /// surfaceContainer, скругление 16, тонкая рамка outlineVariant, отступы 12.
  Widget _card(NewsItem n) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final date = _shortDate(n.date);
    final title = _translated[n.link] ?? n.title;
    // Ширина картинки: экран минус поля списка (16+16), поля карточки (12+12).
    // Оригиналы бывают по 4000 px: без cacheWidth каждый декод съедает ~2 МБ
    // памяти на карточку (сохранено с прошлой правки).
    final width = MediaQuery.sizeOf(context).width - 32 - _cardPad * 2;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final cacheWidth = (width * dpr).round().clamp(320, 1600);

    return Material(
      color: cs.surfaceContainer,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(_cardRadius),
        side: BorderSide(color: cs.outlineVariant),
      ),
      child: InkWell(
        // Тап сразу открывает источник во внешнем браузере (отзыв 23.11, п.3);
        // долгое нажатие оставляет прежнюю шторку как запасной путь.
        onTap: () => _open(n.link),
        onLongPress: () => _showDetails(n),
        child: Padding(
          padding: _cardPadding,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (n.image.isNotEmpty)
                ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: AspectRatio(
                    aspectRatio: 16 / 9,
                    child: Image.network(
                      n.image,
                      width: double.infinity,
                      fit: BoxFit.cover,
                      cacheWidth: cacheWidth,
                      filterQuality: FilterQuality.medium,
                      errorBuilder: (_, __, ___) => ColoredBox(
                        color: cs.surfaceContainerHigh,
                        child: Center(
                          child: Icon(Icons.newspaper_outlined,
                              size: 28, color: cs.onSurfaceVariant),
                        ),
                      ),
                    ),
                  ),
                ),
              if (n.image.isNotEmpty) const SizedBox(height: 10),
              Text(
                title,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                  height: 1.25,
                  color: cs.onSurface,
                ),
              ),
              if (n.summary.isNotEmpty) ...[
                const SizedBox(height: 6),
                // Полного текста сервер не отдаёт (summary до 240 символов),
                // поэтому показываем всё, что пришло: 4 строки вместо 2
                // (отзыв 23.11, п.4 — «а тут писать новости полностью»).
                Text(
                  n.summary,
                  maxLines: 4,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: cs.onSurfaceVariant, height: 1.35),
                ),
              ],
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '${n.source}${date.isEmpty ? '' : ' · $date'}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall
                          ?.copyWith(color: cs.onSurfaceVariant),
                    ),
                  ),
                  const SizedBox(width: 8),
                  // Подсказка вместо шторки: тап уводит в источник
                  // (отзыв 23.11, п.4 — «Открыть источник →»).
                  Text(
                    tr('Открыть источник →'),
                    style: theme.textTheme.labelSmall
                        ?.copyWith(color: cs.primary),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
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
                // Расстояние между карточками 14 px (отзыв 23.11, п.1).
                separatorBuilder: (_, __) => const SizedBox(height: _cardGap),
                itemBuilder: (_, i) => _card(items[i]),
              ),
      ),
    );
  }
}
