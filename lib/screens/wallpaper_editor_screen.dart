import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../i18n/i18n.dart';
import '../services/local_db_service.dart';
import '../theme/backdrop_tint.dart';
import '../widgets/value_wheel.dart';
import '../theme/wallpaper.dart';

/// Редактор обоев на весь экран: тап — поставить фигуру, палец — двигать, два пальца — размер и поворот.
/// Видны только фон и кнопки «выйти», «назад», «сохранить» (плюс выбор вида фигуры снизу).
class WallpaperEditorScreen extends StatefulWidget {
  final LocalDbService db;
  final String kind;
  const WallpaperEditorScreen({super.key, required this.db, this.kind = 'home'});

  @override
  State<WallpaperEditorScreen> createState() => _WallpaperEditorScreenState();
}

class _WallpaperEditorScreenState extends State<WallpaperEditorScreen> {
  late final List<EraseShape> _original;
  List<EraseShape> _shapes = [];
  final List<List<EraseShape>> _history = [];
  int _sel = -1;
  String _type = 'circle';
  bool _moved = false;
  double _baseSize = 0.4, _baseRot = 0;

  @override
  void initState() {
    super.initState();
    _original = [for (final e in BackdropTint.shapes) e.copy()];
    _shapes = [for (final e in _original) e.copy()];
  }

  void _push() => _history.add([for (final e in _shapes) e.copy()]);

  void _apply() {
    BackdropTint.previewShapes([for (final e in _shapes) e.copy()]);
    setState(() {});
  }

  void _exit() {
    BackdropTint.previewShapes(_original); // отмена: вернуть сохранённое
    Navigator.pop(context);
  }

  void _save() {
    BackdropTint.saveShapes(widget.db, [for (final e in _shapes) e.copy()]);
    Navigator.pop(context);
  }

  void _undo() {
    if (_history.isEmpty) return;
    _shapes = _history.removeLast();
    _sel = _sel.clamp(-1, _shapes.length - 1);
    _apply();
  }

  int _hit(Offset p, Size s) {
    final m = math.min(s.width, s.height);
    for (var i = _shapes.length - 1; i >= 0; i--) {
      final e = _shapes[i];
      if (BackdropTint.eraseTypes.indexOf(e.type) >= 5) continue;
      if ((Offset(e.x * s.width, e.y * s.height) - p).distance <= m * 0.5 * e.size + 24) return i;
    }
    return -1;
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _exit();
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: LayoutBuilder(builder: (context, c) {
          final size = Size(c.maxWidth, c.maxHeight);
          return Stack(children: [
            const Positioned.fill(child: SizedBox()),
            Positioned.fill(child: Wallpaper(kind: widget.kind)),
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapUp: (d) {
                  _push();
                  _shapes.add(EraseShape(type: _type, x: d.localPosition.dx / size.width, y: d.localPosition.dy / size.height));
                  _sel = _shapes.length - 1;
                  _apply();
                },
                onScaleStart: (d) {
                  _moved = false;
                  final h = _hit(d.localFocalPoint, size);
                  if (h >= 0) _sel = h;
                  if (_sel >= 0) {
                    _baseSize = _shapes[_sel].size;
                    _baseRot = _shapes[_sel].rot;
                  }
                  setState(() {});
                },
                onScaleUpdate: (d) {
                  if (_sel < 0 || _sel >= _shapes.length) return;
                  if (!_moved) {
                    _moved = true;
                    _push();
                  }
                  final e = _shapes[_sel];
                  e.x = (e.x + d.focalPointDelta.dx / size.width).clamp(0.0, 1.0).toDouble();
                  e.y = (e.y + d.focalPointDelta.dy / size.height).clamp(0.0, 1.0).toDouble();
                  if (d.pointerCount >= 2) {
                    e.size = (_baseSize * d.scale).clamp(0.05, 1.6).toDouble();
                    e.rot = _baseRot + d.rotation;
                  }
                  _apply();
                },
              ),
            ),
            // Контур выбранной фигуры.
            if (_sel >= 0 && _sel < _shapes.length)
              Positioned.fill(
                child: IgnorePointer(child: CustomPaint(painter: _SelPainter(_shapes[_sel], cs.primary))),
              ),
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Row(children: [
                  _btn(Icons.close, tr('Выйти'), _exit),
                  const Spacer(),
                  _btn(Icons.undo, tr('Назад'), _history.isEmpty ? null : _undo),
                  const SizedBox(width: 8),
                  _btn(Icons.check, tr('Сохранить'), _save),
                ]),
              ),
            ),
            Align(
              alignment: Alignment.bottomCenter,
              child: SafeArea(
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    if (_sel >= 0 && _sel < _shapes.length)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                        decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(14)),
                        child: Column(children: [
                          ValueWheel(
                            label: tr('Размытие края'),
                            value: _shapes[_sel].soft,
                            onChanged: (v) {
                              _shapes[_sel].soft = v;
                              _apply();
                            },
                          ),
                          ValueWheel(
                            label: tr('Сила стирания'),
                            value: _shapes[_sel].strength,
                            onChanged: (v) {
                              _shapes[_sel].strength = v;
                              _apply();
                            },
                          ),
                          TextButton(
                            onPressed: () {
                              _push();
                              _shapes.removeAt(_sel);
                              _sel = -1;
                              _apply();
                            },
                            child: Text(tr('Удалить фигуру')),
                          ),
                        ]),
                      ),
                    const SizedBox(height: 6),
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(children: [
                        for (final e in const [
                          ('circle', 'Круг'),
                          ('star', 'Звезда'),
                          ('triangle', 'Треугольник'),
                          ('square', 'Квадрат'),
                          ('band', 'Полоса'),
                          ('left', 'Слева'),
                          ('right', 'Справа'),
                          ('top', 'Сверху'),
                          ('bottom', 'Снизу'),
                        ])
                          Padding(
                            padding: const EdgeInsets.only(right: 6),
                            child: ChoiceChip(label: Text(tr(e.$2)), selected: _type == e.$1, onSelected: (_) => setState(() => _type = e.$1)),
                          ),
                      ]),
                    ),
                  ]),
                ),
              ),
            ),
          ]);
        }),
      ),
    );
  }

  Widget _btn(IconData icon, String tip, VoidCallback? onTap) => Material(
        color: Colors.black54,
        shape: const CircleBorder(),
        child: IconButton(icon: Icon(icon, color: onTap == null ? Colors.white30 : Colors.white), tooltip: tip, onPressed: onTap),
      );
}

class _SelPainter extends CustomPainter {
  final EraseShape e;
  final Color color;
  _SelPainter(this.e, this.color);

  @override
  void paint(Canvas canvas, Size s) {
    final r = math.min(s.width, s.height) * 0.5 * e.size;
    canvas.drawCircle(
      Offset(e.x * s.width, e.y * s.height),
      r,
      Paint()
        ..color = color.withValues(alpha: 0.8)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );
  }

  @override
  bool shouldRepaint(_SelPainter o) => true;
}
