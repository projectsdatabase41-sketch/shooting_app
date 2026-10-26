import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Пункт веера: значок/надпись, подпись и действие.
class FanItem {
  final Widget child;
  final String label;
  final bool active;
  final VoidCallback onSelect;
  const FanItem({required this.child, required this.label, required this.onSelect, this.active = false});
}

/// Одна кнопка, из которой веером вверх раскрываются действия. Тап — раскрыть (выбрать нажатием), а если не
/// отпускать палец и потянуть к нужному пункту — он выбирается при отпускании.
class FanButton extends StatefulWidget {
  final Widget icon;
  final String tooltip;
  final List<FanItem> items;
  const FanButton({super.key, required this.icon, required this.items, this.tooltip = ''});

  @override
  State<FanButton> createState() => _FanButtonState();
}

class _FanButtonState extends State<FanButton> {
  static const double _radius = 76, _itemSize = 50;
  final _link = LayerLink();
  final _hot = ValueNotifier<int?>(null);
  OverlayEntry? _entry;
  Offset _start = Offset.zero;
  bool _dragged = false, _wasOpen = false;

  /// Смещение пункта [i] от центра кнопки: дуга от «чуть правее вверх» до «влево».
  Offset _offsetOf(int i, int n) {
    final deg = n == 1 ? 0.0 : -15 + i * (100 / (n - 1));
    final a = deg * math.pi / 180;
    return Offset(-_radius * math.sin(a), -_radius * math.cos(a));
  }

  Offset _centerGlobal() {
    final box = context.findRenderObject() as RenderBox;
    return box.localToGlobal(box.size.center(Offset.zero));
  }

  void _show() {
    final n = widget.items.length;
    _entry = OverlayEntry(
      builder: (ctx) => Stack(children: [
        Positioned.fill(child: GestureDetector(behavior: HitTestBehavior.translucent, onTap: _hide)),
        for (var i = 0; i < n; i++)
          Positioned(
            left: 0,
            top: 0,
            child: CompositedTransformFollower(
              link: _link,
              showWhenUnlinked: false,
              targetAnchor: Alignment.center,
              followerAnchor: Alignment.center,
              offset: _offsetOf(i, n),
              child: ValueListenableBuilder<int?>(
                valueListenable: _hot,
                builder: (_, hot, __) => _bubble(ctx, widget.items[i], hot == i),
              ),
            ),
          ),
      ]),
    );
    Overlay.of(context).insert(_entry!);
  }

  Widget _bubble(BuildContext ctx, FanItem it, bool hot) {
    final cs = Theme.of(ctx).colorScheme;
    return Column(mainAxisSize: MainAxisSize.min, children: [
      if (hot)
        Container(
          margin: const EdgeInsets.only(bottom: 4),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(color: cs.inverseSurface, borderRadius: BorderRadius.circular(10)),
          child: Text(it.label, style: TextStyle(color: cs.onInverseSurface, fontSize: 12)),
        ),
      GestureDetector(
        onTap: () {
          _hide();
          it.onSelect();
        },
        child: AnimatedScale(
          scale: hot ? 1.2 : 1,
          duration: const Duration(milliseconds: 100),
          child: Material(
            elevation: 4,
            shape: const CircleBorder(),
            color: it.active ? cs.primaryContainer : cs.surfaceContainerHigh,
            child: SizedBox(
              width: _itemSize,
              height: _itemSize,
              child: Center(
                child: DefaultTextStyle.merge(
                  style: TextStyle(fontWeight: FontWeight.w900, color: it.active ? cs.primary : cs.onSurface),
                  child: IconTheme.merge(data: IconThemeData(color: it.active ? cs.primary : cs.onSurface), child: it.child),
                ),
              ),
            ),
          ),
        ),
      ),
    ]);
  }

  void _hide() {
    _entry?.remove();
    _entry = null;
    _hot.value = null;
  }

  int? _hit(Offset global) {
    final c = _centerGlobal();
    final n = widget.items.length;
    for (var i = 0; i < n; i++) {
      if ((c + _offsetOf(i, n) - global).distance <= _itemSize * 0.7) return i;
    }
    return null;
  }

  void _down(PointerDownEvent e) {
    _start = e.position;
    _dragged = false;
    _wasOpen = _entry != null;
    if (!_wasOpen) _show();
  }

  void _move(PointerMoveEvent e) {
    if (_entry == null) return;
    if (!_dragged && (e.position - _start).distance > 12) _dragged = true;
    if (_dragged) _hot.value = _hit(e.position);
  }

  void _up(PointerUpEvent e) {
    if (_dragged) {
      final i = _hit(e.position);
      _hide();
      if (i != null) widget.items[i].onSelect();
    } else if (_wasOpen) {
      _hide();
    }
  }

  @override
  void dispose() {
    _entry?.remove();
    _hot.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final button = CompositedTransformTarget(
      link: _link,
      child: Listener(
        onPointerDown: _down,
        onPointerMove: _move,
        onPointerUp: _up,
        onPointerCancel: (_) => _hide(),
        child: SizedBox(width: 48, height: 48, child: Center(child: widget.icon)),
      ),
    );
    return widget.tooltip.isEmpty ? button : Tooltip(message: widget.tooltip, child: button);
  }
}
