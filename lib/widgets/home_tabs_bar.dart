import '../theme/glass.dart';
import 'dart:math' as math;
import '../theme/app_transitions.dart';
import 'dart:ui' show ImageFilter;

import 'package:flutter/foundation.dart' show ValueListenable, ValueNotifier;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../i18n/i18n.dart';
import '../services/chat_auth_service.dart';
import '../services/chat_messages_repository.dart';
import '../state/app_data_store.dart';
import '../state/home_tabs_view_model.dart';
import '../state/personalization_view_model.dart';

/// Значок вкладки; у мессенджера — красный кружок в углу, если есть
/// непрочитанные сообщения.
class TabIcon extends StatefulWidget {
  final String id;
  final IconData icon;
  final Color? color;
  final double? size;
  const TabIcon({super.key, required this.id, required this.icon, this.color, this.size});

  @override
  State<TabIcon> createState() => _TabIconState();
}

class _TabIconState extends State<TabIcon> {
  @override
  void initState() {
    super.initState();
    if (widget.id == 'messenger') {
      // Начальное значение — после первого кадра, чтобы не трогать базу в build.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          ChatMessagesRepository(context.read<AppDataStore>().db).refreshTotalUnread();
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final icon = Icon(widget.icon, color: widget.color, size: widget.size);
    if (widget.id != 'messenger') return icon;
    return ListenableBuilder(
      listenable: Listenable.merge(
          [ChatMessagesRepository.totalUnread, ChatAuthService.pendingFriends]),
      builder: (_, __) {
        final n = ChatMessagesRepository.totalUnread.value +
            ChatAuthService.pendingFriends.value;
        return Stack(
        clipBehavior: Clip.none,
        children: [
          icon,
          if (n > 0)
            Positioned(
              top: -2,
              right: -3,
              child: Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  color: Colors.red,
                  shape: BoxShape.circle,
                  border: Border.all(color: Theme.of(context).colorScheme.surface, width: 1.5),
                ),
              ),
            ),
        ],
        );
      },
    );
  }
}

/// Значок + подпись одной вкладки нижней навигации.
class HomeTabSpec {
  final IconData icon;
  final String label;
  const HomeTabSpec({required this.icon, required this.label});
}

/// Единственная одновременно открытая всплывашка-крестик на всё
/// приложение — второе долгое нажатие (в любом из режимов отображения)
/// просто закрывает предыдущую вместо двух одновременно висящих.
OverlayEntry? _hidePopup;

/// Крестик над значком (решение пользователя): появляется, когда
/// ОТПУСТИЛИ значок после удержания — не важно, сдвинули его при этом
/// или нет. Нажатие на крестик скрывает вкладку; нажатие куда угодно
/// ещё просто закрывает всплывашку, ничего не меняя. Общая реализация
/// для `HomeTabsBar` (режим "страницы") и `HomeTileGrid` (режим
/// "плитки") — оба долго нажимают на один и тот же значок одинаково.
void showHideTabPopup(
    BuildContext context, GlobalKey anchorKey, VoidCallback onHide) {
  _hidePopup?.remove();
  final box = anchorKey.currentContext?.findRenderObject() as RenderBox?;
  if (box == null) return;
  final pos = box.localToGlobal(Offset.zero);

  final entry = OverlayEntry(
    builder: (ctx) => Stack(
      children: [
        // Прозрачный барьер на весь экран — тап куда угодно, кроме
        // самой кнопки ниже, просто закрывает всплывашку без действия.
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => _hidePopup?.remove(),
          ),
        ),
        Positioned(
          left: pos.dx + box.size.width / 2 - 14,
          top: pos.dy - 18,
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: () {
                onHide();
                _hidePopup?.remove();
              },
              child: Container(
                width: 28,
                height: 28,
                decoration: const BoxDecoration(
                    color: Colors.red, shape: BoxShape.circle),
                child: const Icon(Icons.close, size: 16, color: Colors.white),
              ),
            ),
          ),
        ),
      ],
    ),
  );
  _hidePopup = entry;
  Overlay.of(context).insert(entry);
}

/// Нижняя навигация главного экрана (режим "страницы") — как обычная
/// `NavigationBar`, но с редактированием прямо на месте (решение
/// пользователя): удержал значок — можно перетащить туда, куда нужно,
/// средь остальных; отпустил — над ним всплывает крестик (см.
/// `showHideTabPopup`). Вернуть скрытую вкладку — в настройках,
/// "Рабочие пространства".
class HomeTabsBar extends StatefulWidget {
  final HomeTabsViewModel vm;
  final Map<String, HomeTabSpec> specs;
  final String selected;
  final ValueChanged<String> onSelect;

  const HomeTabsBar({
    super.key,
    required this.vm,
    required this.specs,
    required this.selected,
    required this.onSelect,
  });

  @override
  State<HomeTabsBar> createState() => _HomeTabsBarState();
}

class _HomeTabsBarState extends State<HomeTabsBar> {
  final Map<String, GlobalKey> _tileKeys = {};

  GlobalKey _keyFor(String id) => _tileKeys.putIfAbsent(id, GlobalKey.new);

  void _showHidePopup(String id) {
    if (!widget.vm.canHide(id)) return;
    showHideTabPopup(context, _keyFor(id), () => widget.vm.hide(id));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final visible = widget.vm.visible;
    // Тот же фон приложения, что и у AppBar (AppTheme) — иначе нижняя
    // панель осталась бы старого цвета при выбранном пользователем фоне,
    // как уже было с верхней шапкой.
    final background = context
        .watch<PersonalizationViewModel>()
        .appBackgroundFor(Theme.of(context).brightness);

    return Material(
      color: background ?? theme.colorScheme.surfaceContainer,
      child: SafeArea(
        top: false,
        child: SizedBox(
          // Растёт вместе с размером текста, иначе подпись выбранной вкладки
          // при крупном шрифте не помещается.
          height: MediaQuery.textScalerOf(context).scale(80).clamp(80.0, 124.0),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final tileWidth = constraints.maxWidth / visible.length;
              return ReorderableListView(
                scrollDirection: Axis.horizontal,
                buildDefaultDragHandles: false,
                onReorder: widget.vm.move,
                onReorderEnd: (index) =>
                    _showHidePopup(widget.vm.visible[index]),
                children: [
                  for (final id in visible)
                    _tile(context, id, tileWidth, key: ValueKey(id)),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _tile(BuildContext context, String id, double width,
      {required Key key}) {
    final spec = widget.specs[id];
    if (spec == null) return SizedBox(key: key, width: width);
    final theme = Theme.of(context);
    final isSelected = id == widget.selected;
    final color = isSelected
        ? theme.colorScheme.primary
        : theme.colorScheme.onSurfaceVariant;

    return SizedBox(
      key: key,
      width: width,
      child: InkResponse(
        key: _keyFor(id),
        onTap: () => widget.onSelect(id),
        containedInkWell: true,
        highlightShape: BoxShape.rectangle,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            TabIcon(id: id, icon: spec.icon, color: color),
            // Подпись только у выбранной — так же, как было у
            // NavigationBar (onlyShowSelected): семь вкладок на узком
            // экране с подписью у каждой не помещаются.
            if (isSelected) ...[
              const SizedBox(height: 2),
              Text(tr(spec.label),
                  maxLines: 1,
                  softWrap: false,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall?.copyWith(color: color)),
            ],
          ],
        ),
      ),
    );
  }
}

/// Режим "плитки" — один рабочий стол (решение пользователя): все
/// вкладки квадратными плитками в два столбика, тап открывает вкладку
/// отдельным экраном (с обычной кнопкой "назад" — сюда же и возвращает).
/// Выбор/скрытие/порядок — та же модель и тот же жест (удержать,
/// перетащить, отпустить — крестик), что у `HomeTabsBar`, только
/// перетаскивание в `GridView` не встроено во Flutter и собрано вручную
/// на `LongPressDraggable`/`DragTarget` (аналога `ReorderableListView`
/// для сетки в стандартной библиотеке нет).
/// Вид плиток главного экрана: сплошные (цвет + тень) или «стекло»
/// (прозрачность + размытие фона, как кнопки в шапке). Хранится в color_prefs.
class TileStyle {
  static final ValueNotifier<bool?> _glass = ValueNotifier(null);
  static bool? _cached; // читаем из базы один раз; уведомляем только при смене
  /// Множитель прозрачности «стекла» (0.2 — почти прозрачно … 2 — плотнее).
  static double alpha = 1.0;

  /// Уровень тени / объёма плиток (0 — плоские … 2 — выраженный 3D).
  static double shadow = 1.0;

  static ValueListenable<bool?> get listenable => _glass;

  static String? _get(dynamic db, String k) {
    final r = db.db.select('SELECT hex FROM color_prefs WHERE key = ?', [k]);
    return r.isEmpty ? null : '${r.first['hex']}';
  }

  static void _put(dynamic db, String k, String v) => db.db.execute(
      'INSERT INTO color_prefs (key, hex) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET hex = excluded.hex', [k, v]);

  static bool isGlass(dynamic db) {
    if (_cached != null) return _cached!;
    alpha = (double.tryParse(_get(db, 'tile_alpha') ?? '') ?? 1.0).clamp(0.2, 2.0).toDouble();
    shadow = (double.tryParse(_get(db, 'tile_shadow') ?? '') ?? 1.0).clamp(0.0, 2.0).toDouble();
    _cached = _get(db, 'tile_glass') == '1';
    GlassTheme.sync(_cached!, alpha);
    return _cached!;
  }

  /// Перечитать из базы (после отмены правок в настройках): память и база снова совпадают.
  static void reload(dynamic db) {
    _cached = null;
    isGlass(db);
    _bump();
  }

  static void setGlass(dynamic db, bool v) {
    _put(db, 'tile_glass', v ? '1' : '0');
    _cached = v;
    _glass.value = v;
    GlassTheme.sync(v, alpha);
  }

  static void setAlpha(dynamic db, double v) {
    alpha = v;
    GlassTheme.sync(_cached ?? false, v);
    _put(db, 'tile_alpha', '$v');
    _glass.value = _cached; // перерисовать плитки
    _bump();
  }

  static void setShadow(dynamic db, double v) {
    shadow = v;
    _put(db, 'tile_shadow', '$v');
    _bump();
  }

  static void _bump() {
    final v = _glass.value;
    _glass.value = null;
    _glass.value = v;
  }
}

class HomeTileGrid extends StatefulWidget {
  final HomeTabsViewModel vm;
  final Map<String, HomeTabSpec> specs;
  final ValueChanged<String> onSelect;

  const HomeTileGrid(
      {super.key,
      required this.vm,
      required this.specs,
      required this.onSelect});

  @override
  State<HomeTileGrid> createState() => _HomeTileGridState();
}

class _HomeTileGridState extends State<HomeTileGrid> {
  void _styleChanged() {
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    TileStyle.listenable.addListener(_styleChanged);
  }

  @override
  void dispose() {
    TileStyle.listenable.removeListener(_styleChanged);
    super.dispose();
  }

  final Map<String, GlobalKey> _tileKeys = {};
  String? _dragging;

  /// Индекс ячейки, над которой сейчас завис держащийся палец —
  /// `null`, пока не наведено ни на одну (решение пользователя: другие
  /// плитки должны расступаться ЖИВЬЁМ, ещё до отпускания, а не только
  /// после — иначе непонятно, сработает ли перенос вообще).
  int? _hoverIndex;

  /// Плитка, которую сейчас держат пальцем (не путать с `_dragging` —
  /// тот только про перетаскивание, этот про обычное нажатие) — решение
  /// пользователя "добавь больше 3D эффектов, где можешь": та же физика
  /// вдавливания, что у `Raised3DButton`, только своя копия (плитка
  /// остаётся ещё и `DragTarget`/`LongPressDraggable`, обычную кнопку
  /// внутрь не завернуть).
  String? _pressedId;

  GlobalKey _keyFor(String id) => _tileKeys.putIfAbsent(id, GlobalKey.new);

  void _showHidePopup(String id) {
    if (!widget.vm.canHide(id)) return;
    showHideTabPopup(context, _keyFor(id), () => widget.vm.hide(id));
  }

  static const _padding = 16.0;

  /// Чуть теснее с каждой лишней колонкой (решение пользователя).
  double get _spacing => (16.0 - (_crossAxisCount - 2) * 2).clamp(8.0, 16.0);

  /// Щипок двумя пальцами — 2..5 плиток в ширину, зазор чуть уменьшается
  /// при большем числе колонок (решение пользователя). Тот же приём, что
  /// у `_PhotoGrid` в chat_contact_panel_screen.dart: `Listener`, а не
  /// `GestureDetector`, — только наблюдает за пальцами, не отбирает жест
  /// у `LongPressDraggable`/`DragTarget` плиток.
  final Map<int, Offset> _pointers = {};
  double? _startDist;

  double _dist() {
    final p = _pointers.values.take(2).toList();
    return (p[0] - p[1]).distance;
  }

  void _pinchDown(PointerDownEvent e) {
    _pointers[e.pointer] = e.position;
    if (_pointers.length == 2) _startDist = math.max(_dist(), 1);
  }

  void _pinchMove(PointerMoveEvent e) {
    if (!_pointers.containsKey(e.pointer)) return;
    _pointers[e.pointer] = e.position;
    if (_startDist == null || _pointers.length < 2) return;
    final ratio = _dist() / _startDist!;
    // Развели — крупнее (меньше колонок), свели — мельче (больше колонок).
    final cols = widget.vm.tileColumns;
    final next = ratio > 1.25 ? cols - 1 : (ratio < 0.8 ? cols + 1 : cols);
    if (next == cols) return;
    widget.vm.tileColumns = next;
    _startDist = math.max(_dist(), 1);
  }

  void _pinchUp(PointerEvent e) {
    _pointers.remove(e.pointer);
    if (_pointers.length < 2) _startDist = null;
  }

  /// Колонок на самом деле: не меньше выбранного щипком и достаточно, чтобы плитка не
  /// превышала [HomeTabsViewModel.tileMaxPx] (широкие экраны).
  int? _effCols;
  int get _crossAxisCount => _effCols ?? widget.vm.tileColumns;

  // Меньше плитка (больше колонок при зуме) — меньше значок, а подпись при
  // 4+ колонках вовсе не помещается разборчиво (решение пользователя:
  // убрать текст совсем, а не переносить его на две строки).
  // Ноутбук (экран шире 600 px): размер значка и подпись — по реальному размеру
  // плитки, а не по числу колонок (иначе на широком экране значки мелкие и без текста).
  double _tilePx = 0;
  bool _wide = false;
  double get _tileIconSize {
    final byCols = switch (_crossAxisCount) { <= 2 => 40.0, 3 => 32.0, _ => 26.0 };
    return _wide ? math.max(byCols, math.min(_tilePx * 0.34, 64.0)) : byCols;
  }

  bool get _showTileLabel => _crossAxisCount <= 3 || (_wide && _tilePx >= 100);

  /// Куда встанет каждая плитка, если отпустить ПРЯМО СЕЙЧАС — та же
  /// поправка на индекс, что и в `HomeTabsViewModel.move` (иначе
  /// предпросмотр во время перетаскивания не совпадал бы с тем, что
  /// реально происходит на отпускании).
  List<String> _previewOrder(List<String> ids) {
    final dragging = _dragging;
    final hover = _hoverIndex;
    if (dragging == null || hover == null) return ids;
    final from = ids.indexOf(dragging);
    if (from < 0) return ids;
    var target = hover;
    if (target > from) target -= 1;
    if (target < 0) target = 0;
    if (target >= ids.length) target = ids.length - 1;
    if (target == from) return ids;
    final list = [...ids];
    final item = list.removeAt(from);
    list.insert(target, item);
    return list;
  }

  /// Плитки не в `GridView` (решение пользователя: "более плавная
  /// анимация перемещения плиток") — обычная сетка перекладывает виджеты
  /// в новые ячейки МГНОВЕННО, без перехода. Здесь каждая плитка сама
  /// вычисляет свой пиксельный прямоугольник и едет туда через
  /// `AnimatedPositioned`, с `key: ValueKey(id)` — тем же элементом, не
  /// пересозданным, поэтому Flutter действительно анимирует переезд, а
  /// не крестфейд одного виджета в другой.
  @override
  Widget build(BuildContext context) {
    final ids = widget.vm.visible;
    final preview = _previewOrder(ids);
    final screenW = MediaQuery.sizeOf(context).width;
    _wide = screenW > 600;
    _effCols = math.max(widget.vm.tileColumns, (screenW / widget.vm.tileMaxPx).ceil()).clamp(2, 10);
    final rows = (ids.length / _crossAxisCount).ceil();

    return Listener(
      onPointerDown: _pinchDown,
      onPointerMove: _pinchMove,
      onPointerUp: _pinchUp,
      onPointerCancel: _pinchUp,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final tileSize = (constraints.maxWidth -
                  _padding * 2 -
                  _spacing * (_crossAxisCount - 1)) /
              _crossAxisCount;
          _tilePx = tileSize;
          final gaps = rows > 0 ? rows - 1 : 0;
          final contentHeight =
              _padding * 2 + rows * tileSize + gaps * _spacing;

          Rect rectFor(int index) {
            final row = index ~/ _crossAxisCount;
            final col = index % _crossAxisCount;
            final x = _padding + col * (tileSize + _spacing);
            final y = _padding + row * (tileSize + _spacing);
            return Rect.fromLTWH(x, y, tileSize, tileSize);
          }

          return SingleChildScrollView(
            child: SizedBox(
              height: contentHeight,
              child: Stack(
                children: [
                  // Позиция каждой плитки — её место в ПРЕДПРОСМОТРЕ
                  // (расступились или нет), а исходный индекс (для
                  // DragTarget/vm.move) — из настоящего порядка `ids`.
                  for (var originalIndex = 0;
                      originalIndex < ids.length;
                      originalIndex++)
                    AnimatedPositioned(
                      key: ValueKey(ids[originalIndex]),
                      duration: const Duration(milliseconds: 220),
                      curve: Curves.easeOutCubic,
                      left: rectFor(preview.indexOf(ids[originalIndex])).left,
                      top: rectFor(preview.indexOf(ids[originalIndex])).top,
                      width: rectFor(preview.indexOf(ids[originalIndex])).width,
                      height:
                          rectFor(preview.indexOf(ids[originalIndex])).height,
                      child: _buildTile(
                          context, ids[originalIndex], originalIndex),
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildTile(BuildContext context, String id, int index) {
    // Плитка на 20% меньше своей ячейки (решение пользователя) —
    // FractionallySizedBox вместо уменьшения самой сетки: разница уходит
    // в отступ вокруг плитки, а не в размер занимаемого места.
    return Center(
      child: FractionallySizedBox(
        widthFactor: 0.8,
        heightFactor: 0.8,
        child: DragTarget<String>(
          onWillAcceptWithDetails: (details) => details.data != id,
          onMove: (details) {
            if (_hoverIndex != index) setState(() => _hoverIndex = index);
          },
          onLeave: (data) {
            if (_hoverIndex == index) setState(() => _hoverIndex = null);
          },
          onAcceptWithDetails: (details) {
            final oldIndex = widget.vm.visible.indexOf(details.data);
            if (oldIndex < 0) return;
            widget.vm.move(oldIndex, index);
            setState(() => _hoverIndex = null);
          },
          builder: (context, candidateData, rejectedData) =>
              LongPressDraggable<String>(
            data: id,
            feedback: SizedBox(
                width: 96,
                height: 96,
                child: _tileCard(context, id, elevated: true)),
            childWhenDragging:
                Opacity(opacity: 0.3, child: _tileCard(context, id)),
            onDragStarted: () => setState(() => _dragging = id),
            onDraggableCanceled: (_, __) => setState(() {
              _dragging = null;
              _hoverIndex = null;
            }),
            onDragEnd: (_) {
              setState(() {
                _dragging = null;
                _hoverIndex = null;
              });
              _showHidePopup(id);
            },
            child:
                KeyedSubtree(key: _keyFor(id), child: _tileCard(context, id)),
          ),
        ),
      ),
    );
  }

  Widget _tileCard(BuildContext context, String id, {bool elevated = false}) {
    final spec = widget.specs[id];
    if (spec == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    // Плитки — самые заметные "кнопки" рабочего стола, поэтому реагируют
    // на цвета приложения из настроек (решение пользователя), а не
    // только обычные Filled/ElevatedButton.
    final personalization = context.watch<PersonalizationViewModel>();
    final bg =
        personalization.appButtonFor(cs.brightness) ?? cs.surfaceContainerHigh;
    var fg = personalization.appButtonTextFor(cs.brightness) ?? cs.primary;
    // «Стекло» просвечивает фон, цвет самой кнопки там не при чём; иначе (светлая
    // тема: белый на белом) берём цвет текста темы, если контраст слабый.
    final under = TileStyle.isGlass(context.read<AppDataStore>().db) ? cs.surface : bg;
    double lum(Color c) => c.computeLuminance();
    final hi = math.max(lum(fg), lum(under)) + 0.05, lo = math.min(lum(fg), lum(under)) + 0.05;
    if (hi / lo < 3) fg = cs.onSurface;
    // Вдавливание — только у "живой" плитки на месте, не у теней
    // перетаскивания (elevated — палец уже держит её приподнятой).
    final pressed = !elevated && _pressedId == id;
    final canTap = _dragging == null;

    final glass = TileStyle.isGlass(context.read<AppDataStore>().db);
    return _scatter(context, id, GestureDetector(
      onTapDown: canTap ? (_) => setState(() => _pressedId = id) : null,
      onTapCancel: () => setState(() => _pressedId = null),
      onTapUp: (_) => setState(() => _pressedId = null),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 90),
        curve: Curves.easeOut,
        transform: Matrix4.translationValues(0, pressed ? 3 : 0, 0),
        decoration: glass
            ? (TileStyle.shadow < 0.05
                ? null
                : BoxDecoration(
                    borderRadius: BorderRadius.circular(16),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: ((pressed ? 0.08 : 0.18) * TileStyle.shadow).clamp(0.0, 0.7)),
                        offset: Offset(0, (pressed ? 1 : 5) * TileStyle.shadow),
                        blurRadius: (pressed ? 3 : 12) * TileStyle.shadow,
                      ),
                    ],
                  ))
            : BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Color.lerp(bg, Colors.white, 0.10)!,
              Color.lerp(bg, Colors.black, 0.08)!
            ],
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(
                  alpha: ((pressed ? 0.10 : (elevated ? 0.35 : 0.22)) * TileStyle.shadow).clamp(0.0, 0.8)),
              offset: Offset(0, (pressed ? 1 : (elevated ? 8 : 4)) * TileStyle.shadow),
              blurRadius: (pressed ? 2 : (elevated ? 12 : 6)) * TileStyle.shadow,
            ),
          ],
        ),
        child: _glassWrap(
          glass,
          cs.brightness == Brightness.dark,
          pressed,
          Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(16),
          child: InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: canTap
                ? () {
                    TileOpen.capture(id);
                    widget.onSelect(id);
                  }
                : null,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  TabIcon(id: id, icon: spec.icon, size: _tileIconSize, color: fg),
                  if (_showTileLabel) ...[
                    const SizedBox(height: 8),
                    Text(
                      tr(spec.label),
                      textAlign: TextAlign.center,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelMedium?.copyWith(color: fg),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
        ),
      ),
    ));
  }

  /// Тип «Разброс»: при открытии другого экрана плитка уходит к ближайшему краю.
  Widget _scatter(BuildContext context, String id, Widget tile) {
    // запоминаем, где плитка на экране (нужно для «превращения»)
    return Builder(builder: (bc) {
      TileOpen.contexts[id] = bc;
      final type = AnimSettings.type;
      if (!AnimSettings.enabled || (type != AnimType.scatter && type != AnimType.morph)) return tile;
      final anim = ModalRoute.of(bc)?.secondaryAnimation;
      if (anim == null) return tile;
      return AnimatedBuilder(
        animation: anim,
        child: tile,
        builder: (ctx, child) {
          final t = Curves.easeInCubic.transform(anim.value);
          if (t == 0) return child!;
          final box = ctx.findRenderObject();
          final screen = MediaQuery.sizeOf(ctx);
          var dx = 0.0, dy = 0.0;
          if (box is RenderBox && box.hasSize && box.attached) {
            final c = box.localToGlobal(box.size.center(Offset.zero));
            if (type == AnimType.morph) {
              // выбранная плитка заменяется «превращением»; остальные — прочь от неё
              if (TileOpen.id == id) return Opacity(opacity: 0, child: child);
              final o = TileOpen.rect?.center ?? screen.center(Offset.zero);
              var v = c - o;
              if (v.distance < 1) v = const Offset(0, 1);
              final d = v / v.distance * (screen.longestSide * 0.6);
              dx = d.dx;
              dy = d.dy;
            } else {
              final d = {'l': c.dx, 'r': screen.width - c.dx, 't': c.dy, 'b': screen.height - c.dy};
              final k = d.entries.reduce((a, b) => a.value <= b.value ? a : b).key;
              dx = switch (k) { 'l' => -(c.dx + box.size.width), 'r' => screen.width - c.dx + box.size.width, _ => 0.0 };
              dy = switch (k) { 't' => -(c.dy + box.size.height), 'b' => screen.height - c.dy + box.size.height, _ => 0.0 };
            }
          }
          return Opacity(
              opacity: (1 - t).clamp(0.0, 1.0), child: Transform.translate(offset: Offset(dx * t, dy * t), child: child));
        },
      );
    });
  }

  /// «Стекло»: полупрозрачная заливка + размытие фона + тонкая рамка.
  Widget _glassWrap(bool glass, bool dark, bool pressed, Widget child) {
    if (!glass) return child;
    final r = BorderRadius.circular(16);
    return ClipRRect(
      borderRadius: r,
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: r,
            color: Colors.white.withValues(
                alpha: ((dark ? (pressed ? 0.16 : 0.09) : (pressed ? 0.7 : 0.5)) * TileStyle.alpha).clamp(0.02, 0.95)),
            border: Border.all(color: (dark ? Colors.white : Colors.black).withValues(alpha: dark ? 0.16 : 0.08)),
          ),
          child: child,
        ),
      ),
    );
  }
}
