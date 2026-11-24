import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';

import '../i18n/i18n.dart';
import '../state/app_data_store.dart';
import '../services/call_service.dart';
import '../services/local_db_service.dart';
import '../widgets/app_backdrop.dart';
import '../widgets/app_loader.dart';

import '../widgets/glass_pill.dart';
import 'step_viewer_common.dart' show catalogErrorView;
import 'step_viewer_screen.dart';

/// Каталог 3D-моделей: сетка превью с сервера звонков
/// (`GET <воркер>/models/index`).
///
/// С 24.11 содержимое каталога живёт в переиспользуемом
/// [ModelsCatalogBody]: владелец просил один экран 3D-модуля, а каталог —
/// окошком «почти на весь экран» поверх вьюера (отзыв 24.11). Обёртка
/// [ModelsCatalogScreen] осталась для старого пути — вкладка теперь
/// открывает единый `StepViewerScreen`, но каталог как отдельная страница
/// никуда не делись (не ломаем то, что могло прижиться).
///
/// Адрес воркера нигде не показывается и не логируется: и ссылки на модель,
/// и ошибки сети остаются внутри этого файла — в интерфейсе только названия,
/// категории и готовая 3D-сцена. Стиль и поведение — по образцу экрана
/// новостей (`lib/screens/news_screen.dart`): кэш показывается сразу,
/// сеть догоняет в фоне.
class ModelsCatalogScreen extends StatefulWidget {
  const ModelsCatalogScreen({super.key});

  @override
  State<ModelsCatalogScreen> createState() => _ModelsCatalogScreenState();
}

class _ModelsCatalogScreenState extends State<ModelsCatalogScreen> {
  /// Переход к модели: адрес собирает [ModelsCatalog.modelUrl] и внутрь
  /// вьюера передаётся напрямую — пользователь его не видит и в диалогах
  /// не печатается.
  void _open(String id) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => StepViewerScreen(modelUrl: ModelsCatalog.modelUrl(id)),
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

/// Содержимое каталога: поиск, чипы категорий, сетка превью, кэш и
/// ошибка с повтором. Переиспользуется страницей [ModelsCatalogScreen]
/// и окошком каталога внутри [StepViewerScreen] (владелец 24.11):
/// тап по карточке отдаёт id наружу через [onPick], навигацию решает
/// вызывающий.
class ModelsCatalogBody extends StatefulWidget {
  /// Выбор модели: получают готовый id записи каталога, адрес модели
  /// собирает вызывающий (см. `ModelsCatalog.modelUrl`).
  final void Function(String id) onPick;

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
  /// Идёт фоновая подгрузка: спиннер живёт рядом с поиском, список не
  /// заменяем (как на новостях, отзыв владельца 23.11, п.2 — «подгрузку
  /// в фоне»).
  bool _refreshing = false;

  /// Итог последнего обновления: сети не было. Кэш при этом остаётся на
  /// экране, снизу появляется подпись.
  bool _loadFailed = false;

  /// Появился ли список из кэша: нужно, чтобы отличить «ошибка и пусто»
  /// (полноценный экран ошибки) от «ошибка, но показан кэш» (подпись).
  bool _hasAnyItems = false;

  String _query = '';

  /// Выбранная категория: null — «Все».
  String? _category;

  late final TextEditingController _search = TextEditingController();
  late final LocalDbService _db = context.read<AppDataStore>().db;

  @override
  void initState() {
    super.initState();
    // 1) Сначала поднимаем сохранённый каталог — экран открывается мгновенно,
    //    без ожидания сети (как кэш новостей, отзыв владельца 23.11).
    _hasAnyItems = ModelsCatalog.loadCached(_db);
    // 2) Обновление в фоне: первый build увидит _refreshing = true и нарисует
    //    спиннер рядом с поиском, список не блокируется.
    _refresh(force: false, notify: false);
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  /// Фоновое обновление каталога. При ошибке показанный список (из кэша или
  /// памяти) не стираем — пользователю не оставляем пустой экран.
  Future<void> _refresh({required bool force, bool notify = true}) async {
    if (_refreshing) return;
    _refreshing = true;
    if (notify) setState(() {});
    final ok = await ModelsCatalog.refresh(db: _db, force: force);
    if (!mounted) return;
    setState(() {
      _refreshing = false;
      _loadFailed = !ok;
      if (ModelsCatalog.items.isNotEmpty) _hasAnyItems = true;
    });
  }

  /// Категории текущего каталога по алфавиту + «Все» в начале.
  List<String> get _categories {
    final set = <String>{
      for (final m in ModelsCatalog.items)
        if (m.category.trim().isNotEmpty) m.category,
    };
    return set.toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
  }

  /// Поиск и фильтр категории — только по уже загруженному списку, без
  /// сетевых запросов (как фильтр новостей: отзыв владельца 23.11, п.1).
  List<CatalogModel> get _filtered {
    final all = ModelsCatalog.items;
    final q = _query.trim().toLowerCase();
    return [
      for (final m in all)
        if ((_category == null || m.category == _category) &&
            (q.isEmpty ||
                m.name.toLowerCase().contains(q) ||
                m.category.toLowerCase().contains(q)))
          m,
    ];
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final items = _filtered;
    final loading = _refreshing && !_hasAnyItems;

    if (loading) {
      // Первый запуск без кэша: центрированный загрузчик.
      return const Center(child: AppLoader());
    }
    if (!_hasAnyItems && _loadFailed) {
      // Сети нет и кэша тоже — экран ошибки с повтором (требование D).
      // Код ошибки виден только в режиме разработчика: обычному
      // пользователю «HTTP 401» ничего не говорит.
      return catalogErrorView(
        context,
        errorCode: ModelsCatalog.lastErrorCode,
        onRetry: () => _refresh(force: true),
      );
    }
    if (!_hasAnyItems) {
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

    final cs = theme.colorScheme;
    final categories = _categories;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(height: widget.topInset, width: double.infinity),
        // Поиск по названию + фоновое обновление. «Обновить» переехало сюда
        // из шапки: в окошке поверх вьюера шапки-страницы нет (владелец
        // 24.11 — каталог показывается целиком одним блоком).
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
          child: Row(
            children: [
              Expanded(
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
              IconButton(
                tooltip: tr('Обновить'),
                onPressed: _refreshing ? null : () => _refresh(force: true),
                icon: _refreshing
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.refresh),
              ),
            ],
          ),
        ),
        // Категории: «Все» + все, что пришло от сервера. Горизонтальная
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
        // Подпись «показан сохранённый каталог»: сеть не ответила, но кэш
        // уже на экране — пустой экран недопустим (как в новостях,
        // отзыв владельца 23.11, п.2).
        if (_loadFailed)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Row(
              children: [
                Icon(Icons.cloud_off_outlined,
                    size: 14, color: cs.onSurfaceVariant),
                const SizedBox(width: 6),
                Text(
                  tr('Показан сохранённый каталог'),
                  style: theme.textTheme.labelSmall
                      ?.copyWith(color: cs.onSurfaceVariant),
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

  /// Сетка карточек: 2 колонки на телефоне, 3–4 на широком экране
  /// (просьба владельца 23.11). Высоту ячейки считаем из ширины карточки:
  /// превью 4:3 + название в 2 строки + категория.
  Widget _grid(ThemeData theme, List<CatalogModel> items) {
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
  /// как карточки новостей (стиль каталога по образцу news_screen).
  /// Владелец 24.11: «там будут расположены модели в виде картинки».
  Widget _card(CatalogModel m, double tileW) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    // Превью декодируем в размер карточки × devicePixelRatio: оригиналы
    // бывают большими, без cacheWidth каждый кадр съедает лишнюю память
    // (тот же приём, что в новостях).
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final cacheWidth = (tileW * dpr).round().clamp(320, 1600);
    final url = ModelsCatalog.previewUrl(m.id);

    return Material(
      color: cs.surfaceContainer,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: cs.outlineVariant),
      ),
      child: InkWell(
        onTap: () => widget.onPick(m.id),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AspectRatio(
              aspectRatio: 4 / 3,
              child: Image.network(
                url,
                fit: BoxFit.cover,
                cacheWidth: cacheWidth,
                filterQuality: FilterQuality.medium,
                // Иконка вместо картинки, если превью не догрузилось.
                errorBuilder: (_, __, ___) => ColoredBox(
                  color: cs.surfaceContainerHigh,
                  child: Center(
                    child: Icon(Icons.view_in_ar_outlined,
                        size: 32, color: cs.onSurfaceVariant),
                  ),
                ),
              ),
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
}

/// Каталог моделей: загрузка с воркера звонков и кэш в `color_prefs`
/// (механизм тот же, что у кэша новостей `news_feed_cache` —
/// ключ `models_catalog_cache`, просьба владельца 23.11).
///
/// Ключи и адреса сервера отсюда не логируются и на экран не выводятся.
class ModelsCatalog {
  ModelsCatalog._();

  /// Последняя загруженная модель каталога (память).
  static List<CatalogModel> items = const [];

  /// Время обновления на сервере ({updatedAt} из ответа).
  static String? updatedAt;

  /// Код последней ошибки (HTTP-статус или тип исключения). Показываем
  /// только в режиме разработчика — обычному пользователю он не нужен
  /// (требование D, владелец 24.11).
  static String? lastErrorCode;

  static DateTime? _fetchedAt;

  /// Пауза между фоновыми обновлениями: каталог меняется редко, дёргать
  /// сервер на каждом открытии экрана незачем.
  static const _minInterval = Duration(minutes: 30);

  static const _kCache = 'models_catalog_cache';

  /// Ссылки собраны здесь и наружу не выходят: экран получает готовый адрес
  /// или объект `CatalogModel`, но не печатает URL нигде.
  static String modelUrl(String id) => '${CallService.url}/models/$id/model.glb';
  static String previewUrl(String id) => '${CallService.url}/models/$id/preview.png';

  /// Поднимает сохранённый каталог БЕЗ сети. Возвращает true, если нашлось.
  static bool loadCached(LocalDbService db) {
    try {
      final rows =
          db.db.select('SELECT hex FROM color_prefs WHERE key = ?', [_kCache]);
      if (rows.isEmpty) return false;
      final data = jsonDecode('${rows.first['hex']}');
      if (data is! Map) return false;
      final list = _parseList(data['items']);
      if (list.isEmpty) return false;
      items = list;
      updatedAt = '${data['updatedAt'] ?? ''}';
      return true;
    } catch (_) {
      return false; // битый кэш не страшен — просто ждём сеть
    }
  }

  /// Забирает каталог с сервера. [force] — игнорировать паузу между
  /// запросами (кнопка «Обновить»). Возвращает true при успехе; ошибки не
  /// пробрасываем, показанный список не трогаем.
  static Future<bool> refresh(
      {required LocalDbService db, bool force = false}) async {
    final now = DateTime.now();
    if (!force &&
        _fetchedAt != null &&
        now.difference(_fetchedAt!) < _minInterval) {
      return items.isNotEmpty; // в паузу сеть не трогаем — ошибки нет
    }
    _fetchedAt = now;
    lastErrorCode = null;
    // Пока идёт запрос, всё равно показываем сохранённое.
    if (items.isEmpty) loadCached(db);
    try {
      final res = await http
          .get(Uri.parse('${CallService.url}/models/index'))
          .timeout(const Duration(seconds: 20));
      if (res.statusCode != 200) {
        // Понятная причина сбоя для режима разработчика (требование D).
        lastErrorCode = 'HTTP ${res.statusCode}';
        return false;
      }
      final data = jsonDecode(utf8.decode(res.bodyBytes));
      if (data is! Map) {
        lastErrorCode = 'bad payload';
        return false;
      }
      final list = _parseList(data['items']);
      // Пустой ответ сервера — не повод затирать показанное.
      if (list.isEmpty) return items.isNotEmpty;
      items = list;
      updatedAt = '${data['updatedAt'] ?? ''}';
      try {
        db.db.execute(
          'INSERT INTO color_prefs (key, hex) VALUES (?, ?) '
          'ON CONFLICT(key) DO UPDATE SET hex = excluded.hex',
          [
            _kCache,
            jsonEncode({
              'updatedAt': updatedAt,
              'items': [
                for (final m in list)
                  {
                    'id': m.id,
                    'name': m.name,
                    'category': m.category,
                    'sizeBytes': m.sizeBytes,
                    'hasStep': m.hasStep,
                  }
              ],
            }),
          ],
        );
      } catch (_) {
        // Кэш в базу не лёг — это не мешает уже загруженному списку.
      }
      return true;
    } catch (e) {
      // Сеть отвалилась: показанное (кэш/память) не трогаем, экран покажет
      // подпись или экран ошибки в зависимости от того, был ли список.
      lastErrorCode = '${e.runtimeType}';
      return false;
    }
  }

  static List<CatalogModel> _parseList(Object? raw) =>
      (raw as List? ?? const [])
          .whereType<Map>()
          .map((m) => CatalogModel(
                id: '${m['id'] ?? ''}',
                name: '${m['name'] ?? ''}',
                category: '${m['category'] ?? ''}',
                sizeBytes: m['sizeBytes'] is num ? (m['sizeBytes'] as num).toInt() : 0,
                hasStep: m['hasStep'] == true,
              ))
          .where((m) => m.id.isNotEmpty && m.name.isNotEmpty)
          .toList();
}

/// Одна запись каталога: то, что отдаёт `GET <воркер>/models/index`.
class CatalogModel {
  final String id;
  final String name;
  final String category;
  final int sizeBytes;
  final bool hasStep;

  const CatalogModel({
    required this.id,
    required this.name,
    this.category = '',
    this.sizeBytes = 0,
    this.hasStep = false,
  });
}
