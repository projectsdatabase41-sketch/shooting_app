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

/// Геометрия веера.
///
/// Вынесена из виджета в чистую функцию — её проверяет тест без виджетов.
///
/// Зачем: у кнопки «+» в поле ввода чата (низ экрана) хвост дуги «11→7
/// часов» уходил за нижний край, и часть пунктов была недоступна. Здесь
/// считаем так, чтобы все пункты оставались внутри безопасной области и
/// над клавиатурой: сначала пробуем задуманную дугу, потом более короткую
/// (только выше кнопки), потом перевёрнутую (для кнопки у верхнего края),
/// и лишь в совсем тесном окне прижимаем точки к краям.
class FanLayout {
  FanLayout._();

  /// Дуги-кандидаты: от «11 часов» к «7» (20°…140°), затем короче — к «3»
  /// (20°…90°, при 90° пункт ровно на уровне кнопки и ниже не опускается).
  static const List<(double, double)> windows = [
    (20.0, 140.0),
    (20.0, 90.0),
    (25.0, 85.0),
  ];

  /// Смещения пунктов относительно центра кнопки.
  ///
  /// [center] — центр кнопки в координатах экрана, [screen] — размер окна,
  /// [safe] — системные отступы, [keyboard] — высота клавиатуры снизу.
  static List<Offset> offsets({
    required Offset center,
    required Size screen,
    required EdgeInsets safe,
    required double keyboard,
    required double itemSize,
    required int count,
    required bool mirror,
    double margin = 8,
  }) {
    if (count <= 0) return const [];

    // Прямоугольник, в котором обязаны оказаться ЦЕНТРЫ пунктов.
    final rect = Rect.fromLTRB(
      safe.left + margin + itemSize / 2,
      safe.top + margin + itemSize / 2,
      screen.width - safe.right - margin - itemSize / 2,
      screen.height - safe.bottom - keyboard - margin - itemSize / 2,
    );

    List<Offset> build(double from, double to, double radius, bool flipY,
        {bool flipX = false}) {
      final out = <Offset>[];
      for (var i = 0; i < count; i++) {
        final deg =
            count == 1 ? (from + to) / 2 : from + i * (to - from) / (count - 1);
        final a = deg * math.pi / 180;
        out.add(Offset(
          (mirror != flipX ? 1 : -1) * radius * math.sin(a),
          (flipY ? 1 : -1) * radius * math.cos(a),
        ));
      }
      return out;
    }

    bool fits(List<Offset> items) => items.every((d) {
          final p = center + d;
          return p.dx >= rect.left - 0.01 &&
              p.dx <= rect.right + 0.01 &&
              p.dy >= rect.top - 0.01 &&
              p.dy <= rect.bottom + 0.01;
        });

    // Радиус, при котором соседние пункты не налезают друг на друга:
    // длина дуги = шаг между пунктами × (count − 1).
    double baseRadius(double from, double to) {
      final span = (to - from).abs() * math.pi / 180;
      final need = span < 1e-6 ? 0.0 : (itemSize + 10) * (count - 1) / span;
      return math.max(110.0, need);
    }

    // Порядок попыток: как задумано (влево-вверх), потом в другую сторону по
    // горизонтали, потом вниз — чтобы веер у любого края экрана нашёл себе место.
    for (final flipY in [false, true]) {
      for (final flipX in [false, true]) {
        for (final (from, to) in windows) {
          var r = baseRadius(from, to);
          // Растим радиус, пока дуга не влезет: дальше от кнопки — больше места.
          for (var step = 0; step < 24; step++) {
            final items = build(from, to, r, flipY, flipX: flipX);
            if (fits(items)) return items;
            r += 10;
          }
        }
      }
    }

    // Совсем тесно (узкое окно, огромный системный шрифт): прижимаем внутрь.
    final base = build(windows.first.$1, windows.first.$2,
        baseRadius(windows.first.$1, windows.first.$2), false);
    if (rect.right <= rect.left || rect.bottom <= rect.top) return base;
    return [
      for (final d in base)
        Offset(
          ((center.dx + d.dx).clamp(rect.left, rect.right)) - center.dx,
          ((center.dy + d.dy).clamp(rect.top, rect.bottom)) - center.dy,
        )
    ];
  }
}

/// Одна кнопка, из которой веером вверх раскрываются действия. Тап — раскрыть (выбрать нажатием), а если не
/// отпускать палец и потянуть к нужному пункту — он выбирается при отпускании.
class FanButton extends StatefulWidget {
  final Widget icon;
  final String tooltip;
  final List<FanItem> items;
  /// Если кнопка стоит вне навигатора (поверх всего приложения), веер рисуется в оверлее этого навигатора.
  final GlobalKey<NavigatorState>? navigatorKey;
  /// Кнопка у левого края: веер раскрывается вправо.
  final bool mirror;
  const FanButton({super.key, required this.icon, required this.items, this.tooltip = '', this.navigatorKey, this.mirror = false});

  @override
  State<FanButton> createState() => _FanButtonState();
}

class _FanButtonState extends State<FanButton> {
  static const double _itemSize = 50;
  double _radius = 114;
  /// Куда встали пункты при раскрытии (см. FanLayout). Пусто — пересчитаем.
  List<Offset> _offsets = const [];
  final _link = LayerLink();
  final _hot = ValueNotifier<int?>(null);
  OverlayEntry? _entry;
  Offset _start = Offset.zero;
  bool _dragged = false, _wasOpen = false;

  /// Смещение пункта [i] от центра кнопки: дуга от «11 часов» до «7 часов».
  ///
  /// Раскладку считает FanLayout по реальным границам экрана; здесь только
  /// берём готовое и не даём упасть, если веер ещё не раскрыт.
  Offset _offsetOf(int i, int n) {
    if (i < _offsets.length) return _offsets[i];
    return _legacyOffsets(n)[i];
  }

  /// Старая формула — только на случай, если MediaQuery недоступен.
  List<Offset> _legacyOffsets(int n) {
    final out = <Offset>[];
    for (var i = 0; i < n; i++) {
      final deg = n == 1 ? 60.0 : 20 + i * (120 / (n - 1));
      final a = deg * math.pi / 180;
      out.add(Offset(
        (widget.mirror ? 1 : -1) * _radius * math.sin(a),
        -_radius * math.cos(a),
      ));
    }
    return out;
  }

  List<Offset> _layout(int n) {
    final mq = MediaQuery.maybeOf(context);
    if (mq == null) return _legacyOffsets(n);
    return FanLayout.offsets(
      center: _centerGlobal(),
      screen: mq.size,
      safe: mq.padding,
      keyboard: mq.viewInsets.bottom,
      itemSize: _itemSize,
      count: n,
      mirror: widget.mirror,
    );
  }

  Offset _centerGlobal() {
    final box = context.findRenderObject() as RenderBox;
    return box.localToGlobal(box.size.center(Offset.zero));
  }

  void _show() {
    final n = widget.items.length;
    _offsets = _layout(n);
    // Много пунктов — дуга шире, чтобы кнопки не налезали друг на друга (дуга 120° ≈ 2,09 рад).
    _radius = _offsets.isEmpty
        ? math.max(114, (_itemSize + 6) * (n - 1) / 2.09)
        : _offsets.map((o) => o.distance).reduce(math.max);
    _entry = OverlayEntry(
      builder: (ctx) => Stack(children: [
        // Затемнение вокруг кнопки: пункты веера лучше видны на любом фоне.
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: _hide,
            child: DecoratedBox(decoration: BoxDecoration(gradient: _shade(ctx))),
          ),
        ),
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
    (widget.navigatorKey?.currentState?.overlay ?? Overlay.of(context)).insert(_entry!);
  }

  RadialGradient _shade(BuildContext ctx) {
    final size = MediaQuery.sizeOf(ctx);
    final c = _centerGlobal();
    return RadialGradient(
      center: Alignment(c.dx / size.width * 2 - 1, c.dy / size.height * 2 - 1),
      radius: (_radius + 110) / size.shortestSide,
      colors: const [Color(0xB3000000), Color(0x00000000)],
    );
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
