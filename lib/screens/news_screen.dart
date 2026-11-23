import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../i18n/i18n.dart';
import '../services/chat_translation_service.dart';
import '../services/local_db_service.dart';
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
  /// Идёт ли фоновая подгрузка. Спиннер живёт в шапке и список не заменяет
  /// (отзыв владельца 23.11, п.2 — «загрузка долго длится. лучше запускать
  /// подгрузку новостей в фоне»).
  bool _refreshing = false;

  /// Активный фильтр ленты (отзыв 23.11, п.1 — «хотелось бы их выбирать»).
  /// По умолчанию пустой: показываем всё, как раньше.
  NewsFilter _filter = const NewsFilter();

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
    final db = context.read<AppDataStore>().db;
    // 1) Сразу поднимаем сохранённую ленту и фильтр — экран открывается с
    //    готовым списком, без ожидания сети (отзыв 23.11, п.2).
    NewsService.loadCached(db);
    _filter = NewsFilter.load(db);
    // 2) Обновление уходит в фон. notify: false — потому что setState в
    //    initState не нужен: первый build уже увидит _refreshing = true и
    //    нарисует спиннер в шапке, не задерживая список.
    _refresh(force: false, notify: false);
  }

  /// Фоновое обновление. Список на экране не блокируется: во время запроса
  /// виден кэш, в шапке крутится спиннер (отзыв 23.11, п.2).
  Future<void> _refresh({required bool force, bool notify = true}) async {
    if (_refreshing) return;
    final db = context.read<AppDataStore>().db;
    _refreshing = true;
    if (notify) setState(() {});
    await NewsService.refresh(db: db, force: force);
    if (!mounted) return;
    setState(() => _refreshing = false);
    if (NewsService.lastRefreshFailed) {
      // Ошибка сети не стирает показанную ленту — только короткое сообщение
      // (отзыв 23.11, п.2: «не должно подвисать», пустой экран недопустим).
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(
          content: Text(tr('Не удалось обновить новости — показана сохранённая лента')),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
    _translateVisible(db);
  }

  /// Шторка фильтров: источники чекбоксами + слова (отзыв 23.11, п.1).
  /// Фильтрация — по уже загруженному списку, новых запросов не делаем.
  Future<void> _openFilter() async {
    final db = context.read<AppDataStore>().db;
    final result = await showModalBottomSheet<NewsFilter>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      // Явный непрозрачный фон: в режиме «стекло» тема отдаёт его
      // полупрозрачным, и шторка просвечивала (отзыв 23.11, п.2).
      backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
      builder: (_) => _FilterSheet(sources: _knownSources(), initial: _filter),
    );
    if (result == null || !mounted) return;
    result.save(db);
    setState(() => _filter = result);
  }

  /// Уникальные источники текущей ленты, по алфавиту — список для шторки.
  List<String> _knownSources() {
    final set = <String>{
      for (final n in NewsService.items)
        if (n.source.trim().isNotEmpty) n.source,
    };
    return set.toList()..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
  }

  /// Пустая лента (сервер ещё ничего не отдал) — прежнее поведение.
  Widget _emptyState(ThemeData theme) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            tr('Новостей пока нет. Они обновляются на сервере дважды в день — загляните позже.'),
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium,
          ),
        ),
      );

  /// Фильтр ничего не нашёл — понятное сообщение и кнопка сброса, чтобы не
  /// оставлять пользователя с пустым экраном (п.1 отзыва 23.11).
  Widget _nothingFound(ThemeData theme) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.filter_alt_off_outlined,
                  size: 40, color: theme.colorScheme.onSurfaceVariant),
              const SizedBox(height: 12),
              Text(
                tr('Ничего не найдено по фильтру'),
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium,
              ),
              const SizedBox(height: 8),
              TextButton.icon(
                onPressed: _resetFilter,
                icon: const Icon(Icons.filter_alt_off_outlined, size: 18),
                label: Text(tr('Сбросить фильтр')),
              ),
            ],
          ),
        ),
      );

  /// Сброс фильтра прямо из пустого экрана: и в памяти, и в настройках.
  void _resetFilter() {
    const empty = NewsFilter();
    empty.save(context.read<AppDataStore>().db);
    setState(() => _filter = empty);
  }

  /// Переводим первые заголовки на язык системы (как в чате). Ошибки и
  /// лимиты переводчика не мешают: показываем оригинал.
  Future<void> _translateVisible(LocalDbService db) async {
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
    final all = NewsService.items;
    // Фильтрация — только по уже загруженному списку, без сетевых запросов
    // (отзыв 23.11, п.1). Пустой фильтр отдаёт ленту как есть.
    final items = _filter.isActive
        ? [for (final n in all) if (_filter.matches(n)) n]
        : all;
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: GlassHeader(
        title: Text(tr('Новости')),
        actions: [
          // Фильтр новостей (отзыв 23.11, п.1). Точка на иконке = фильтр
          // активен, чтобы это было видно без открытия шторки.
          IconButton(
            tooltip: tr('Фильтры'),
            onPressed: _openFilter,
            icon: Badge(
              isLabelVisible: _filter.isActive,
              child: const Icon(Icons.filter_alt_outlined),
            ),
          ),
          IconButton(
            tooltip: tr('Обновить'),
            // Обновление идёт в фоне и список не заменяет (отзыв 23.11, п.2).
            onPressed: _refreshing ? null : () => _refresh(force: true),
            icon: _refreshing
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.refresh),
          ),
        ],
      ),
      body: AppBackdrop(
        kind: 'settings',
        child: all.isEmpty
            ? _emptyState(theme)
            : items.isEmpty
                ? _nothingFound(theme)
                : ListView.separated(
                    padding: EdgeInsets.fromLTRB(16, MediaQuery.paddingOf(context).top + GlassHeader.height + 12, 16, 32),
                    itemCount: items.length,
                    // Ленивая сборка: ListView строит только видимые карточки,
                    // а запас 600 px держит в работе примерно 3–4 ближайшие
                    // картинки — остальные Image.network начинают грузиться по
                    // мере прокрутки (отзыв 23.11, п.2 — «без подвисаний»).
                    cacheExtent: 600,
                    // Расстояние между карточками 14 px (отзыв 23.11, п.1).
                    separatorBuilder: (_, __) => const SizedBox(height: _cardGap),
                    itemBuilder: (_, i) => _card(items[i]),
                  ),
      ),
    );
  }
}

/// Шторка фильтров: список источников с чекбоксами и поле слов
/// (отзыв владельца 23.11, п.1).
class _FilterSheet extends StatefulWidget {
  final List<String> sources;
  final NewsFilter initial;

  const _FilterSheet({required this.sources, required this.initial});

  @override
  State<_FilterSheet> createState() => _FilterSheetState();
}

class _FilterSheetState extends State<_FilterSheet> {
  /// Черновик фильтра: применяется только по кнопке «Применить», поэтому
  /// закрытие шторки свайпом ничего не меняет.
  late final Set<String> _sources = {...widget.initial.sources};
  late final TextEditingController _words =
      TextEditingController(text: widget.initial.words);

  @override
  void dispose() {
    _words.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Material(
      // Непрозрачный фон по той же причине, что и в _showDetails: тема
      // «стекло» отдаёт modalBackgroundColor полупрозрачным (отзыв 23.11, п.2).
      color: cs.surfaceContainerHighest,
      child: SafeArea(
        top: false,
        child: Padding(
          // Поле слов не должно уезжать под клавиатуру.
          padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
                  child: Text(
                    tr('Фильтры новостей'),
                    style: theme.textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.w600),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                  child: Text(
                    tr('Источники'),
                    style: theme.textTheme.labelMedium
                        ?.copyWith(color: cs.onSurfaceVariant),
                  ),
                ),
                if (widget.sources.isEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                    child: Text(
                      tr('Список источников появится, когда загрузится лента.'),
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: cs.onSurfaceVariant),
                    ),
                  )
                else
                  ConstrainedBox(
                    // Длинный список источников прокручивается внутри шторки,
                    // а не растягивает её на весь экран.
                    constraints: const BoxConstraints(maxHeight: 240),
                    child: ListView.builder(
                      shrinkWrap: true,
                      padding: EdgeInsets.zero,
                      itemCount: widget.sources.length,
                      itemBuilder: (_, i) {
                        final s = widget.sources[i];
                        return CheckboxListTile(
                          value: _sources.contains(s),
                          dense: true,
                          controlAffinity: ListTileControlAffinity.leading,
                          title: Text(
                            s,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodyMedium,
                          ),
                          onChanged: (v) => setState(() {
                            if (v == true) {
                              _sources.add(s);
                            } else {
                              _sources.remove(s);
                            }
                          }),
                        );
                      },
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
                  child: TextField(
                    controller: _words,
                    textInputAction: TextInputAction.search,
                    onChanged: (_) => setState(() {}), // показать/убрать крестик
                    decoration: InputDecoration(
                      labelText: tr('Слова'),
                      hintText: tr('например: винтовка, финал'),
                      isDense: true,
                      border: const OutlineInputBorder(),
                      prefixIcon: const Icon(Icons.search),
                      suffixIcon: _words.text.isEmpty
                          ? null
                          : IconButton(
                              tooltip: tr('Очистить'),
                              icon: const Icon(Icons.clear),
                              onPressed: () => setState(_words.clear),
                            ),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
                  child: Row(
                    children: [
                      // «Сбросить» сразу применяет пустой фильтр и закрывает
                      // шторку — это же действие доступно из пустого экрана.
                      TextButton(
                        onPressed: () =>
                            Navigator.of(context).pop(const NewsFilter()),
                        child: Text(tr('Сбросить')),
                      ),
                      const Spacer(),
                      FilledButton(
                        onPressed: () => Navigator.of(context).pop(
                          NewsFilter(
                            sources: {..._sources},
                            words: _words.text.trim(),
                          ),
                        ),
                        child: Text(tr('Применить')),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
