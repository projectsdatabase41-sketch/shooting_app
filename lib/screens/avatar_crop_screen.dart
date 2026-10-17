import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;

import '../i18n/i18n.dart';
import '../logic/avatar_utils.dart';
import '../widgets/glass_pill.dart';

/// Выбор области фото профиля: фото можно двигать и приближать (щипок или
/// ползунок); круг показывает, как фото будет выглядеть в чате. Возвращает
/// готовую строку base64 (см. [AvatarUtils.cropToBase64]) либо `null`.
class AvatarCropScreen extends StatefulWidget {
  final Uint8List bytes;
  const AvatarCropScreen({super.key, required this.bytes});

  @override
  State<AvatarCropScreen> createState() => _AvatarCropScreenState();
}

class _AvatarCropScreenState extends State<AvatarCropScreen> {
  final _tc = TransformationController();
  img.Image? _decoded;
  double _view = 300; // сторона квадрата просмотра, px
  double _zoom = 1;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _decoded = img.decodeImage(widget.bytes);
  }

  @override
  void dispose() {
    _tc.dispose();
    super.dispose();
  }

  /// Размер картинки в просмотре: меньшая сторона = стороне квадрата.
  Size get _childSize {
    final d = _decoded!;
    final s = _view / (d.width < d.height ? d.width : d.height);
    return Size(d.width * s, d.height * s);
  }

  void _center() {
    final c = _childSize;
    _tc.value = Matrix4.identity()..translate(-(c.width - _view) / 2, -(c.height - _view) / 2);
    _zoom = 1;
  }

  void _setZoom(double z) {
    // масштаб вокруг центра квадрата просмотра
    final m = _tc.value.clone();
    final cur = m.getMaxScaleOnAxis();
    final k = z / cur;
    final focal = Offset(_view / 2, _view / 2);
    final next = Matrix4.identity()
      ..translate(focal.dx, focal.dy)
      ..scale(k)
      ..translate(-focal.dx, -focal.dy);
    _tc.value = next * m;
    setState(() => _zoom = z);
  }

  Future<void> _done() async {
    final d = _decoded;
    if (d == null) return;
    setState(() => _busy = true);
    final inv = Matrix4.inverted(_tc.value);
    final tl = MatrixUtils.transformPoint(inv, Offset.zero);
    final br = MatrixUtils.transformPoint(inv, Offset(_view, _view));
    final s = _childSize.width / d.width; // px просмотра на px картинки
    final b64 = AvatarUtils.cropToBase64(d, tl.dx / s, tl.dy / s, (br.dx - tl.dx) / s);
    if (mounted) Navigator.of(context).pop(b64);
  }

  @override
  Widget build(BuildContext context) {
    final d = _decoded;
    final theme = Theme.of(context);
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: GlassHeader(title: Text(tr('Фото профиля'), style: const TextStyle(fontWeight: FontWeight.w600))),
      body: d == null
          ? Center(child: Text(tr('Не удалось открыть изображение')))
          : LayoutBuilder(builder: (context, box) {
              final side = (box.maxWidth < box.maxHeight ? box.maxWidth : box.maxHeight * 0.5) - 32;
              if ((side - _view).abs() > 1) {
                _view = side;
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (mounted) setState(_center);
                });
              }
              final c = _childSize;
              return SingleChildScrollView(
                  child: Column(children: [
                SizedBox(height: MediaQuery.paddingOf(context).top + GlassHeader.height + 12),
                Center(
                  child: SizedBox(
                    width: _view,
                    height: _view,
                    child: Stack(children: [
                      ClipRect(
                        child: InteractiveViewer(
                          transformationController: _tc,
                          constrained: false,
                          minScale: 1,
                          maxScale: 8,
                          boundaryMargin: EdgeInsets.zero,
                          onInteractionUpdate: (_) => setState(() => _zoom = _tc.value.getMaxScaleOnAxis()),
                          child: SizedBox(width: c.width, height: c.height, child: Image.memory(widget.bytes, fit: BoxFit.fill)),
                        ),
                      ),
                      // затемнение вне круга + кольцо — как фото будет выглядеть в чате
                      IgnorePointer(child: CustomPaint(size: Size(_view, _view), painter: _CirclePainter(theme.colorScheme.primary))),
                    ]),
                  ),
                ),
                const SizedBox(height: 12),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Row(children: [
                    const Icon(Icons.zoom_out, size: 20),
                    Expanded(child: Slider(min: 1, max: 8, value: _zoom.clamp(1, 8).toDouble(), onChanged: _setZoom)),
                    const Icon(Icons.zoom_in, size: 20),
                  ]),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
                  child: Text(tr('Двигайте и приближайте фото: в круге то, что увидят в чате'),
                      textAlign: TextAlign.center, style: theme.textTheme.bodySmall),
                ),
                const SizedBox(height: 16),
                SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                    child: Row(children: [
                      Expanded(child: OutlinedButton(onPressed: () => Navigator.pop(context), child: Text(tr('Отмена')))),
                      const SizedBox(width: 12),
                      Expanded(child: FilledButton(onPressed: _busy ? null : _done, child: Text(tr('Готово')))),
                    ]),
                  ),
                ),
              ]));
            }),
    );
  }
}

class _CirclePainter extends CustomPainter {
  final Color ring;
  _CirclePainter(this.ring);

  @override
  void paint(Canvas canvas, Size size) {
    final r = size.shortestSide / 2;
    final c = size.center(Offset.zero);
    final path = Path()
      ..addRect(Offset.zero & size)
      ..addOval(Rect.fromCircle(center: c, radius: r))
      ..fillType = PathFillType.evenOdd;
    canvas.drawPath(path, Paint()..color = Colors.black54);
    canvas.drawCircle(
        c,
        r,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = ring);
  }

  @override
  bool shouldRepaint(_CirclePainter o) => o.ring != ring;
}

/// Выбор фото из галереи → экран выбора области (круг и масштаб) → base64.
Future<String?> pickAvatarWithCrop(BuildContext context) async {
  final bytes = await AvatarUtils.pickBytes();
  if (bytes == null || !context.mounted) return null;
  return Navigator.of(context).push<String>(MaterialPageRoute(builder: (_) => AvatarCropScreen(bytes: bytes)));
}
