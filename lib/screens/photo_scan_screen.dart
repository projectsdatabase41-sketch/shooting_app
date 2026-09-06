import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;

import '../logic/shot_photo_detection.dart';
import '../models/target_face.dart';
import '../services/shot_photo_service.dart';

/// Функция для `compute()` — обязана быть верхнеуровневой: изолят видит
/// только сам код функции и переданный ей аргумент, никаких замыканий.
List<HoleCandidate> _detectInIsolate(_DetectArgs args) {
  return findCandidateHoles(
    image: args.image,
    center: args.center,
    radiusPx: args.radiusPx,
    caliberRadiusPx: args.caliberRadiusPx,
    knownHolesPx: args.knownHolesPx,
  );
}

class _DetectArgs {
  final GrayImage image;
  final PixelPoint center;
  final double radiusPx;
  final double caliberRadiusPx;
  final List<PixelPoint> knownHolesPx;
  const _DetectArgs({
    required this.image,
    required this.center,
    required this.radiusPx,
    required this.caliberRadiusPx,
    required this.knownHolesPx,
  });
}

/// Определение пробоин по фото мишени.
///
/// Три шага: выбрать фото → совместить круг с краем бланка на фото
/// (калибровка масштаба и центра — по кольцам/краю мишени, а не по
/// отдельной физической метке) → найденные новые пробоины возвращаются
/// вызывающему экрану координатами в мм, он же их и подтверждает —
/// обычной панелью правки на настоящей мишени, которая для этого уже
/// есть и проверена.
///
/// Само фото никогда не сохраняется приложением: путь к нему не
/// открывается (`file_picker` с `withData: true` отдаёт байты в
/// память), и они просто перестают существовать вместе с этим экраном.
class PhotoScanScreen extends StatefulWidget {
  final TargetFace face;

  /// Уже известные пробоины (активные и в корзине — физический след на
  /// бумаге остаётся в любом случае) в мм от центра мишени — чтобы не
  /// предлагать их повторно.
  final List<PixelPoint> knownHolesMm;

  const PhotoScanScreen({super.key, required this.face, required this.knownHolesMm});

  @override
  State<PhotoScanScreen> createState() => _PhotoScanScreenState();
}

class _PhotoScanScreenState extends State<PhotoScanScreen> {
  Uint8List? _bytes;
  img.Image? _decoded;
  String? _error;
  bool _busy = false;

  // Калибровка — в координатах ИСХОДНОГО (не отображаемого) фото.
  Offset? _calibCenter;
  double _calibRadius = 0;

  double _displayScale = 1; // display px = natural px * _displayScale

  Future<void> _pick() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await FilePicker.platform.pickFiles(type: FileType.image, withData: true);
      if (result == null || result.files.isEmpty) {
        setState(() => _busy = false);
        return;
      }
      final bytes = result.files.first.bytes;
      if (bytes == null) throw const ShotPhotoException('Не удалось прочитать файл');
      final decoded = ShotPhotoService.decode(bytes);
      setState(() {
        _bytes = bytes;
        _decoded = decoded;
        _calibCenter = Offset(decoded.width / 2, decoded.height / 2);
        _calibRadius = (decoded.width < decoded.height ? decoded.width : decoded.height) * 0.35;
      });
    } catch (e) {
      setState(() => _error = '$e');
    } finally {
      setState(() => _busy = false);
    }
  }

  Future<void> _detect() async {
    final decoded = _decoded;
    final center = _calibCenter;
    if (decoded == null || center == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final analyzed = ShotPhotoService.analyze(decoded);
      final s = analyzed.scale;
      final scaledCenter = PixelPoint(center.dx * s, center.dy * s);
      final scaledRadius = _calibRadius * s;
      final caliberRadiusPx = scaledRadius * (widget.face.caliberMm / 2) / widget.face.faceRadiusMm;
      final knownPx = [
        for (final mm in widget.knownHolesMm)
          PixelPoint(
            scaledCenter.x + mm.x / widget.face.faceRadiusMm * scaledRadius,
            scaledCenter.y - mm.y / widget.face.faceRadiusMm * scaledRadius,
          ),
      ];

      final candidates = await compute(
        _detectInIsolate,
        _DetectArgs(
          image: analyzed.image,
          center: scaledCenter,
          radiusPx: scaledRadius,
          caliberRadiusPx: caliberRadiusPx,
          knownHolesPx: knownPx,
        ),
      );

      if (!mounted) return;
      if (candidates.isEmpty) {
        setState(() {
          _busy = false;
          _error = 'Новых пробоин не нашли — либо на фото их не видно, либо круг откалиброван неточно. '
              'Попробуйте подровнять круг по самому краю бланка и снять чуть ровнее.';
        });
        return;
      }

      final points = [
        for (final c in candidates)
          pixelToMm(c.center, scaledCenter, scaledRadius, widget.face.faceRadiusMm),
      ];
      Navigator.of(context).pop(points);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = '$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final decoded = _decoded;
    return Scaffold(
      appBar: AppBar(title: const Text('Фото мишени')),
      body: decoded == null
          ? _buildPickPrompt()
          : Column(
              children: [
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        final aspect = decoded.width / decoded.height;
                        return Center(
                          child: AspectRatio(
                            aspectRatio: aspect,
                            child: LayoutBuilder(
                              builder: (context, box) {
                                _displayScale = box.maxWidth / decoded.width;
                                return _CalibrationOverlay(
                                  bytes: _bytes!,
                                  displayScale: _displayScale,
                                  center: _calibCenter!,
                                  radius: _calibRadius,
                                  onChanged: (c, r) => setState(() {
                                    _calibCenter = c;
                                    _calibRadius = r;
                                  }),
                                );
                              },
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Text(
                    'Совместите круг с краем бланка мишени на фото: тащите за середину, '
                    'чтобы сдвинуть, и за край круга, чтобы изменить размер.',
                    style: Theme.of(context).textTheme.bodySmall,
                    textAlign: TextAlign.center,
                  ),
                ),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                    child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                  ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  child: Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: _busy ? null : () => setState(() => _decoded = null),
                          child: const Text('Другое фото'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: FilledButton(
                          onPressed: _busy ? null : _detect,
                          child: _busy
                              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                              : const Text('Найти пробоины'),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
    );
  }

  Widget _buildPickPrompt() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.photo_camera_outlined, size: 48, color: Theme.of(context).colorScheme.onSurfaceVariant),
            const SizedBox(height: 12),
            Text(
              'Сфотографируйте мишень камерой телефона и выберите снимок здесь — '
              'приложение само в галерею не пишет и файл после разбора не хранит.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _busy ? null : _pick,
              icon: _busy
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.image_outlined),
              label: const Text('Выбрать фото'),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ],
          ],
        ),
      ),
    );
  }
}

/// Фото + перетаскиваемый круг калибровки поверх него. Координаты
/// хранятся в системе ИСХОДНОГО фото — виджет сам переводит экранные
/// жесты через `displayScale`, наружу всегда уходят "настоящие" пиксели.
class _CalibrationOverlay extends StatelessWidget {
  final Uint8List bytes;
  final double displayScale;
  final Offset center;
  final double radius;
  final void Function(Offset center, double radius) onChanged;

  const _CalibrationOverlay({
    required this.bytes,
    required this.displayScale,
    required this.center,
    required this.radius,
    required this.onChanged,
  });

  static const double _handleHitRadius = 24;

  @override
  Widget build(BuildContext context) {
    final displayCenter = center * displayScale;
    final displayRadius = radius * displayScale;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onPanStart: (details) {},
      onPanUpdate: (details) {
        final local = details.localPosition;
        final distFromEdge = (local - displayCenter).distance - displayRadius;
        if (distFromEdge.abs() <= _handleHitRadius) {
          final newRadius = (local - displayCenter).distance / displayScale;
          onChanged(center, newRadius.clamp(10, 5000));
        } else {
          onChanged(center + details.delta / displayScale, radius);
        }
      },
      child: Stack(
        fit: StackFit.expand,
        children: [
          Image.memory(bytes, fit: BoxFit.fill),
          CustomPaint(
            painter: _CalibrationPainter(center: displayCenter, radius: displayRadius),
          ),
        ],
      ),
    );
  }
}

class _CalibrationPainter extends CustomPainter {
  final Offset center;
  final double radius;

  const _CalibrationPainter({required this.center, required this.radius});

  @override
  void paint(Canvas canvas, Size size) {
    final ring = Paint()
      ..color = Colors.amberAccent
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3;
    canvas.drawCircle(center, radius, ring);

    final handle = Paint()..color = Colors.amberAccent;
    canvas.drawCircle(center, 6, handle);
    final edgePoint = center + Offset(radius, 0);
    canvas.drawCircle(edgePoint, 8, handle);
  }

  @override
  bool shouldRepaint(covariant _CalibrationPainter oldDelegate) =>
      oldDelegate.center != center || oldDelegate.radius != radius;
}
