import 'package:flutter/material.dart';

import '../state/home_tabs_view_model.dart';

/// Значок + подпись одной вкладки нижней навигации.
class HomeTabSpec {
  final IconData icon;
  final String label;
  const HomeTabSpec({required this.icon, required this.label});
}

/// Нижняя навигация главного экрана — как обычная `NavigationBar`, но с
/// редактированием прямо на месте (решение пользователя): удержал
/// значок — можно перетащить туда, куда нужно, средь остальных; отпустил
/// — над ним всплывает крестик. Нажатие на крестик скрывает вкладку (не
/// удаляет — вернуть можно в настройках, "Рабочие пространства", или
/// заново открыв её здесь тем же способом никак — только оттуда).
/// Нажатие куда угодно ещё просто прячет крестик, ничего не меняя.
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
  OverlayEntry? _popup;

  GlobalKey _keyFor(String id) => _tileKeys.putIfAbsent(id, GlobalKey.new);

  @override
  void dispose() {
    _popup?.remove();
    super.dispose();
  }

  void _showHidePopup(String id) {
    if (!widget.vm.canHide(id)) return;
    _popup?.remove();
    final box = _keyFor(id).currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return;
    final pos = box.localToGlobal(Offset.zero);

    final entry = OverlayEntry(
      builder: (ctx) => Stack(
        children: [
          // Прозрачный барьер на весь экран — тап куда угодно, кроме
          // самой кнопки ниже, просто закрывает всплывашку без действия
          // (решение пользователя).
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => _popup?.remove(),
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
                  widget.vm.hide(id);
                  _popup?.remove();
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
    _popup = entry;
    Overlay.of(context).insert(entry);
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
                // По решению пользователя: крестик появляется, когда
                // ОТПУСТИЛИ значок после удержания — не важно, сдвинули
                // его при этом или нет (index — уже итоговый).
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
