import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../i18n/i18n.dart';
import '../state/home_tabs_view_model.dart';
import '../state/personalization_view_model.dart';

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
void showHideTabPopup(BuildContext context, GlobalKey anchorKey, VoidCallback onHide) {
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
                decoration: const BoxDecoration(color: Colors.red, shape: BoxShape.circle),
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
    final background = context.watch<PersonalizationViewModel>().appBackgroundFor(Theme.of(context).brightness);

    return Material(
      color: background ?? theme.colorScheme.surfaceContainer,
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 80,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final tileWidth = constraints.maxWidth / visible.length;
              return ReorderableListView(
                scrollDirection: Axis.horizontal,
                buildDefaultDragHandles: false,
                onReorder: widget.vm.move,
                onReorderEnd: (index) => _showHidePopup(widget.vm.visible[index]),
                children: [
                  for (final id in visible) _tile(context, id, tileWidth, key: ValueKey(id)),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _tile(BuildContext context, String id, double width, {required Key key}) {
    final spec = widget.specs[id];
    if (spec == null) return SizedBox(key: key, width: width);
    final theme = Theme.of(context);
    final isSelected = id == widget.selected;
    final color = isSelected ? theme.colorScheme.primary : theme.colorScheme.onSurfaceVariant;

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
            Icon(spec.icon, color: color),
            // Подпись только у выбранной — так же, как было у
            // NavigationBar (onlyShowSelected): семь вкладок на узком
            // экране с подписью у каждой не помещаются.
            if (isSelected) ...[
              const SizedBox(height: 2),
              Text(tr(spec.label), style: theme.textTheme.labelSmall?.copyWith(color: color)),
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
class HomeTileGrid extends StatefulWidget {
  final HomeTabsViewModel vm;
  final Map<String, HomeTabSpec> specs;
  final ValueChanged<String> onSelect;

  const HomeTileGrid({super.key, required this.vm, required this.specs, required this.onSelect});

  @override
  State<HomeTileGrid> createState() => _HomeTileGridState();
}

class _HomeTileGridState extends State<HomeTileGrid> {
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

  static const _spacing = 16.0;
  static const _padding = 16.0;
  static const _crossAxisCount = 2;

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
    final rows = (ids.length / _crossAxisCount).ceil();

    return LayoutBuilder(
      builder: (context, constraints) {
        final tileSize = (constraints.maxWidth - _padding * 2 - _spacing * (_crossAxisCount - 1)) / _crossAxisCount;
        final gaps = rows > 0 ? rows - 1 : 0;
        final contentHeight = _padding * 2 + rows * tileSize + gaps * _spacing;

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
                for (var originalIndex = 0; originalIndex < ids.length; originalIndex++)
                  AnimatedPositioned(
                    key: ValueKey(ids[originalIndex]),
                    duration: const Duration(milliseconds: 220),
                    curve: Curves.easeOutCubic,
                    left: rectFor(preview.indexOf(ids[originalIndex])).left,
                    top: rectFor(preview.indexOf(ids[originalIndex])).top,
                    width: rectFor(preview.indexOf(ids[originalIndex])).width,
                    height: rectFor(preview.indexOf(ids[originalIndex])).height,
                    child: _buildTile(context, ids[originalIndex], originalIndex),
                  ),
              ],
            ),
          ),
        );
      },
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
          builder: (context, candidateData, rejectedData) => LongPressDraggable<String>(
            data: id,
            feedback: SizedBox(width: 96, height: 96, child: _tileCard(context, id, elevated: true)),
            childWhenDragging: Opacity(opacity: 0.3, child: _tileCard(context, id)),
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
            child: KeyedSubtree(key: _keyFor(id), child: _tileCard(context, id)),
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
    final bg = personalization.appButtonFor(cs.brightness) ?? cs.surfaceContainerHigh;
    final fg = personalization.appButtonTextFor(cs.brightness) ?? cs.primary;
    // Вдавливание — только у "живой" плитки на месте, не у теней
    // перетаскивания (elevated — палец уже держит её приподнятой).
    final pressed = !elevated && _pressedId == id;
    final canTap = _dragging == null;

    return GestureDetector(
      onTapDown: canTap ? (_) => setState(() => _pressedId = id) : null,
      onTapCancel: () => setState(() => _pressedId = null),
      onTapUp: (_) => setState(() => _pressedId = null),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 90),
        curve: Curves.easeOut,
        transform: Matrix4.translationValues(0, pressed ? 3 : 0, 0),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color.lerp(bg, Colors.white, 0.10)!, Color.lerp(bg, Colors.black, 0.08)!],
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: pressed ? 0.10 : (elevated ? 0.35 : 0.22)),
              offset: Offset(0, pressed ? 1 : (elevated ? 8 : 4)),
              blurRadius: pressed ? 2 : (elevated ? 12 : 6),
            ),
          ],
        ),
        child: Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(16),
          child: InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: canTap ? () => widget.onSelect(id) : null,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(spec.icon, size: 40, color: fg),
                  const SizedBox(height: 8),
                  Text(
                    tr(spec.label),
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelMedium?.copyWith(color: fg),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
