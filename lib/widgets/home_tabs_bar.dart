import 'package:flutter/material.dart';

import '../state/home_tabs_view_model.dart';

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

    return Material(
      color: theme.colorScheme.surfaceContainer,
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
              Text(spec.label, style: theme.textTheme.labelSmall?.copyWith(color: color)),
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

  GlobalKey _keyFor(String id) => _tileKeys.putIfAbsent(id, GlobalKey.new);

  void _showHidePopup(String id) {
    if (!widget.vm.canHide(id)) return;
    showHideTabPopup(context, _keyFor(id), () => widget.vm.hide(id));
  }

  @override
  Widget build(BuildContext context) {
    final ids = widget.vm.visible;
    return GridView.builder(
      padding: const EdgeInsets.all(16),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        mainAxisSpacing: 16,
        crossAxisSpacing: 16,
        childAspectRatio: 1,
      ),
      itemCount: ids.length,
      itemBuilder: (context, index) {
        final id = ids[index];
        // Плитка на 20% меньше своей ячейки (решение пользователя) —
        // FractionallySizedBox вместо уменьшения самой сетки: позиции
        // ячеек не двигаются, разница уходит в отступ вокруг плитки.
        return Center(
          child: FractionallySizedBox(
            widthFactor: 0.8,
            heightFactor: 0.8,
            child: DragTarget<String>(
              onWillAcceptWithDetails: (details) => details.data != id,
              onAcceptWithDetails: (details) {
                final oldIndex = widget.vm.visible.indexOf(details.data);
                if (oldIndex < 0) return;
                widget.vm.move(oldIndex, index);
              },
              builder: (context, candidateData, rejectedData) => LongPressDraggable<String>(
                data: id,
                feedback: SizedBox(width: 96, height: 96, child: _tileCard(context, id, elevated: true)),
                childWhenDragging: Opacity(opacity: 0.3, child: _tileCard(context, id)),
                onDragStarted: () => setState(() => _dragging = id),
                onDraggableCanceled: (_, __) => setState(() => _dragging = null),
                onDragEnd: (_) {
                  setState(() => _dragging = null);
                  _showHidePopup(id);
                },
                child: KeyedSubtree(key: _keyFor(id), child: _tileCard(context, id)),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _tileCard(BuildContext context, String id, {bool elevated = false}) {
    final spec = widget.specs[id];
    if (spec == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return Material(
      elevation: elevated ? 6 : 0,
      color: cs.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: _dragging == null ? () => widget.onSelect(id) : null,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(spec.icon, size: 40, color: cs.primary),
              const SizedBox(height: 8),
              Text(
                spec.label,
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelMedium,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
