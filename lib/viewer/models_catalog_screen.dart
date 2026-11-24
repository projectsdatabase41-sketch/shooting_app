import 'package:flutter/material.dart';

import '../i18n/i18n.dart';
import '../services/drive_models_catalog.dart';
import '../widgets/app_backdrop.dart';
import '../widgets/app_loader.dart';

import '../widgets/glass_pill.dart';
import 'step_viewer_common.dart' show catalogErrorView;
import 'step_viewer_screen.dart';

/// Каталог 3D-моделей с Google Drive.
///
/// Владелец 24.11: «Модели должны лететь с гугл диска. Я открыл
/// возможность прочитывать по ссылке эти файлы. Сами файлы не
/// скачиваются на устройство и просто просматриваются методом
/// замещения URL». Поэтому данные каталога читаются из ассета
/// `assets/models/catalog.json` (сервис [DriveModelsCatalog]) —
/// сети-запросов к воркеру больше нет, кэш в `color_prefs` тоже не
/// нужен: источником всегда служит ассет, он же живёт в сборке.
///
/// С 24.11 содержимое каталога живёт в переиспользуемом
/// [ModelsCatalogBody]: владелец просил один экран 3D-модуля, а каталог —
/// окошком «почти на весь экран» поверх вьюера (отзыв 24.11). Обёртка
/// [ModelsCatalogScreen] осталась для старого пути — вкладка теперь
/// открывает единый `StepViewerScreen`, но каталог как отдельная страница
/// никуда не делись (не ломаем то, что могло прижиться).
class ModelsCatalogScreen extends StatefulWidget {
  const ModelsCatalogScreen({super.key});

  @override
  State<ModelsCatalogScreen> createState() => _ModelsCatalogScreenState();
}

class _ModelsCatalogScreenState extends State<ModelsCatalogScreen> {
  /// Переход к модели: адрес собирает [DriveModelsCatalog.modelUrl] и
  /// внутрь вьюера передаётся напрямую — пользователь его не видит и в
  /// диалогах не печатается.
  void _open(DriveCatalogModel m) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) =>
          StepViewerScreen(modelUrl: DriveModelsCatalog.modelUrl(m.id)),
    ));
  }

  /// Старый путь: открыть файл с устройства или по ссылке без каталога
  /// (вьюер в полном режиме со своей шапкой — кнопки «Открыть STEP» и
  /// «Открыть по ссылке» там свои).
  void _openFromFile() {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const StepViewerScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: GlassHeader(
        title: Text(tr('3D-модели')),
        actions: [
          // Старое поведение — открыть файл с устройства/по ссылке
          // (сохранено, чтобы простой просмотр не сломался).
          IconButton(
            tooltip: tr('Открыть файл с устройства'),
            icon: const Icon(Icons.folder_open_outlined),
            onPressed: _openFromFile,
          ),
        ],
      ),
      body: AppBackdrop(
        kind: 'settings',
        // Содержимое каталога и в шапке страницы, и в окошке поверх вьюера
        // — одно и то же (требование C, владелец 24.11).
        child: ModelsCatalogBody(
          onPick: _open,
          // Отступ под стеклянной шапкой страницы.
          topInset:
              MediaQuery.paddingOf(context).top + GlassHeader.height + 12,
        ),
      ),
    );
  }
}

/// Содержимое каталога: поиск, чипы категорий, сетка карточек, ошибка
/// ассета с повтором. Переиспользуется страницей [ModelsCatalogScreen]
/// и окошком каталога внутри [StepViewerScreen] (владелец 24.11): тап по
/// карточке отдаёт запись каталога наружу через [onPick], навигацию и
/// сборку ссылки решает вызывающий.
class ModelsCatalogBody extends StatefulWidget {
  /// Выбор модели: получают запись каталога с Google Drive, ссылку на
  /// .stp собирает вызывающий (см. `DriveModelsCatalog.modelUrl`).
  final void Function(DriveCatalogModel model) onPick;

  /// Верхний отступ: на странице каталог живёт под стеклянной шапкой, в
  /// окошке — сразу под собственным заголовком.
  final double topInset;

  const ModelsCatalogBody({
    super.key,
    required this.onPick,
    this.topInset = 0,
  });

  @override
  State<ModelsCatalogBody> createState() => _ModelsCatalogBodyState();
}

class _ModelsCatalogBodyState extends State<ModelsCatalogBody> {
  /// Загрузка ещё идёт (первое чтение ассета): центрированный загрузчик.
  bool _loading = true;

  /// Ассет не прочитался (битый JSON / не попал в сборку) — экран ошибки
  /// с кнопкой «Повторить» (требование E).
  bool _loadFailed = false;

  String _query = '';

  /// Выбранная категория: null — «Все».
  String? _category;

  late final TextEditingController _search = TextEditingController();

  @override
  void initState() {
    super.initState();
    // Каталог — локальный ассет: читаем асинхронно один раз, сетевого
    // обновления больше нет (владелец 24.11 — данные на Drive, список
    // собирается заранее в catalog.json).
    _loadCatalog();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  /// Чтение каталога из ассета через [DriveModelsCatalog] (он кэширует
  /// результат в памяти — повторные открытия экрана бесплатны).
  Future<void> _loadCatalog() async {
    setState(() {
      _loading = true;
      _loadFailed = false;
    });
    final ok = await DriveModelsCatalog.load();
    if (!mounted) return;
    setState(() {
      _loading = false;
      _loadFailed = !ok;
    });
  }

  /// Категории текущего каталога по алфавиту + «Все» в начале.
  List<String> get _categories {
    final set = <String>{
      for (final m in DriveModelsCatalog.items)
        if (m.category.trim().isNotEmpty) m.category,
    };
    return set.toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
  }

  /// Поиск и фильтр категории — по списку из ассета, без сетевых
  /// запросов (как фильтр новостей: отзыв владельца 23.11, п.1).
  List<DriveCatalogModel> get _filtered {
    final all = DriveModelsCatalog.items;
    final q = _query.trim().toLowerCase();
    return [
      for (final m in all)
        if ((_category == null || m.category == _category) &&
            (q.isEmpty ||
                m.name.toLowerCase().contains(q) ||
                m.fileName.toLowerCase().contains(q) ||
                m.category.toLowerCase().contains(q)))
          m,
    ];
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final items = _filtered;

    if (_loading && DriveModelsCatalog.items.isEmpty) {
      // Читаем ассет: центрированный загрузчик.
      return const Center(child: AppLoader());
    }
    if (_loadFailed && DriveModelsCatalog.items.isEmpty) {
      // Ассет не прочитался и ничего прежнего в памяти нет: экран
      // ошибки с повтором (требование E). Код ошибки виден только в
      // режиме разработчика (friendlyErrorDevMode).
      return Center(
        child: catalogErrorView(
          context,
          errorCode: DriveModelsCatalog.lastErrorCode,
          onRetry: _loadCatalog,
        ),
      );
    }
    if (!_loadFailed && DriveModelsCatalog.items.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            tr('Каталог пока пуст'),
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium,
          ),
        ),
      );
    }

    final categories = _categories;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(height: widget.topInset, width: double.infinity),
        // Поиск по названию. Кнопки «Обновить» больше нет: каталог —
        // локальный ассет, сеть обновлять нечего (владелец 24.11 —
        // источник переехал с воркера на Google Drive).
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
          child: TextField(
            controller: _search,
            onChanged: (v) => setState(() => _query = v),
            decoration: InputDecoration(
              isDense: true,
              prefixIcon: const Icon(Icons.search),
              suffixIcon: _query.isEmpty
                  ? null
                  : IconButton(
                      tooltip: tr('Очистить'),
                      icon: const Icon(Icons.clear),
                      onPressed: () => setState(() {
                        _search.clear();
                        _query = '';
                      }),
                    ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              hintText: tr('Поиск по названию'),
            ),
          ),
        ),
        // Категории: «Все» + подпапки из Drive-дерева. Горизонтальная
        // лента, чтобы не съедать высоту сетки.
        if (categories.isNotEmpty)
          SizedBox(
            height: 34,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              children: [
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text(tr('Все')),
                    selected: _category == null,
                    onSelected: (_) => setState(() => _category = null),
                  ),
                ),
                for (final c in categories)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Text(c),
                      selected: _category == c,
                      onSelected: (_) => setState(() => _category = c),
                    ),
                  ),
              ],
            ),
          ),
        Expanded(
          child: items.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      tr('Ничего не найдено'),
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium
                          ?.copyWith(color: cs.onSurfaceVariant),
                    ),
                  ),
                )
              : _grid(theme, items),
        ),
      ],
    );
  }

  /// Ошибка чтения ассета каталога (битый JSON / не попал в сборку):
  /// понятный текст с кнопкой «Повторить» (требование E). Код ошибки
  /// виден только в режиме разработчика — обычному пользователю он ни
  /// о чём не говорит.
  /// Сетка карточек: 2 колонки на телефоне, 3–4 на широком экране
  /// (просьба владельца 23.11). Высоту ячейки считаем из ширины карточки:
  /// превью 4:3 + название в 2 строки + категория.
  Widget _grid(ThemeData theme, List<DriveCatalogModel> items) {
    final width = MediaQuery.sizeOf(context).width;
    final cols = width >= 1200 ? 4 : (width >= 760 ? 3 : 2);
    const gap = 12.0;
    final usable = width - 16 * 2 - gap * (cols - 1);
    final tileW = usable / cols;
    // Высота текстовой части зависит от масштаба шрифта, поэтому считаем
    // её честно — иначе на крупном шрифте подпись упиралась бы в край.
    final scaler = MediaQuery.textScalerOf(context);
    final caption = scaler.scale(14) * 1.25 * 2 + // titleSmall, 2 строки
        scaler.scale(11) * 1.3 + // labelSmall, категория
        26; // поля и зазоры карточки
    final tileH = tileW * 3 / 4 + caption;

    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: cols,
        crossAxisSpacing: gap,
        mainAxisSpacing: gap,
        mainAxisExtent: tileH,
      ),
      itemCount: items.length,
      itemBuilder: (_, i) => _card(items[i], tileW),
    );
  }

  /// Карточка модели: скругление 16, фон surfaceContainer, тонкая рамка —
  /// как карточки новостей. Владелец 24.11: «там будут расположены модели
  /// в виде картинки» — когда на Drive появятся превью, здесь рисуется
  /// `lh3.googleusercontent.com/d/<previewId>`; пока превью нет
  /// (`previewId == null`) — заглушка с иконкой view_in_ar.
  Widget _card(DriveCatalogModel m, double tileW) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return Material(
      color: cs.surfaceContainer,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: cs.outlineVariant),
      ),
      child: InkWell(
        onTap: () => widget.onPick(m),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AspectRatio(
              aspectRatio: 4 / 3,
              child: m.hasPreview
                  ? Image.network(
                      DriveModelsCatalog.previewUrl(m.previewId!),
                      fit: BoxFit.cover,
                      filterQuality: FilterQuality.medium,
                      // Превью не догрузилось — та же заглушка, что без
                      // превью: сетка не «мигает» чужими картинками.
                      errorBuilder: (_, __, ___) => _previewPlaceholder(cs),
                    )
                  : _previewPlaceholder(cs),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    m.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                      height: 1.25,
                      color: cs.onSurface,
                    ),
                  ),
                  if (m.category.trim().isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      m.category,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall
                          ?.copyWith(color: cs.onSurfaceVariant),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Заглушка вместо превью: иконка 3D на фоне surfaceContainer (в
  /// карточке картинок с Drive пока нет — владелец 24.11). Никаких
  /// текстов про ошибку загрузки: превью просто ещё нет.
  Widget _previewPlaceholder(ColorScheme cs) => ColoredBox(
        color: cs.surfaceContainer,
        child: Center(
          child: Icon(Icons.view_in_ar,
              size: 36, color: cs.onSurfaceVariant),
        ),
      );
}
