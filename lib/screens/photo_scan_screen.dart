import 'dart:math' as math;
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;

import '../logic/scoring.dart';
import '../logic/shot_photo_detection.dart';
import '../models/target_face.dart';
import '../services/shot_photo_service.dart';

/// Функции для `compute()` — обязаны быть верхнеуровневыми: изолят видит
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

({PixelPoint center, double radiusPx})? _detectCircleInIsolate(GrayImage image) =>
    detectTargetCircle(image);

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

/// Определение пробоин по фото мишени — можно снять НЕСКОЛЬКО фото подряд
/// в одном заходе (решение пользователя: подтвердил пробоины на одном
/// снимке — экран сразу предлагает следующий, а не уводит на правку).
///
/// Шаги на каждом фото: выбрать снимок → круг мишени подгоняется
/// автоматически (по контрасту с фоном кадра), пользователь может
/// подправить его руками → пробоины ищутся сразу же и показываются
/// точками поверх фото — их можно перетащить, убрать лишнюю или
/// добавить пропущенную → «Подтвердить» добавляет их в общий список
/// внизу и сразу предлагает выбрать следующее фото. «Готово» в шапке
/// завершает заход и возвращает накопленный список вызывающему экрану —
/// тот добавляет все выстрелы разом, без правки по одному.
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
  bool _addMode = false;

  // Калибровка — в координатах ИСХОДНОГО (не отображаемого) фото.
  Offset? _calibCenter;
  double _calibRadius = 0;

  // Кандидаты текущего фото — тоже в координатах исходного фото.
  List<Offset> _candidates = [];

  // Накопленный список подтверждённых пробоин (across фото), в мм.
  final List<PixelPoint> _confirmedMm = [];

  double _displayScale = 1; // display px = natural px * _displayScale

  List<PixelPoint> get _allKnownMm => [...widget.knownHolesMm, ..._confirmedMm];

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
      final analyzed = ShotPhotoService.analyze(decoded);
      final autoCircle = await compute(_detectCircleInIsolate, analyzed.image);

      Offset center;
      double radius;
      if (autoCircle != null) {
        final s = analyzed.scale;
        center = Offset(autoCircle.center.x / s, autoCircle.center.y / s);
        radius = autoCircle.radiusPx / s;
      } else {
        center = Offset(decoded.width / 2, decoded.height / 2);
        radius = (decoded.width < decoded.height ? decoded.width : decoded.height) * 0.35;
      }

      setState(() {
        _bytes = bytes;
        _decoded = decoded;
        _calibCenter = center;
        _calibRadius = radius;
        _candidates = [];
      });
      await _runDetection();
    } catch (e) {
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _runDetection() async {
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
        for (final mm in _allKnownMm)
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
      setState(() {
        _busy = false;
        _candidates = [for (final c in candidates) Offset(c.center.x / s, c.center.y / s)];
        if (_candidates.isEmpty) {
          _error = 'Пробоин не нашли — либо на фото их не видно, либо круг откалиброван неточно. '
              'Можно подровнять круг или добавить точку вручную кнопкой ниже.';
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = '$e';
      });
    }
  }

  PixelPoint _toMm(Offset px) => pixelToMm(
        PixelPoint(px.dx, px.dy),
        PixelPoint(_calibCenter!.dx, _calibCenter!.dy),
        _calibRadius,
        widget.face.faceRadiusMm,
      );

  void _confirmPhoto() {
    setState(() {
      _confirmedMm.addAll(_candidates.map(_toMm));
      _candidates = [];
      _decoded = null;
      _bytes = null;
      _calibCenter = null;
      _addMode = false;
      _error = null;
    });
  }

  void _finish() {
    Navigator.of(context).pop(_confirmedMm);
  }

  @override
  Widget build(BuildContext context) {
    final decoded = _decoded;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Фото мишени'),
        actions: [
          if (_confirmedMm.isNotEmpty)
            TextButton(
              onPressed: _finish,
              child: Text('Готово (${_confirmedMm.length})', style: const TextStyle(color: Colors.white)),
            ),
        ],
      ),
      body: Column(
        children: [
          Expanded(child: decoded == null ? _buildPickPrompt() : _buildReview(decoded)),
          if (_confirmedMm.isNotEmpty) _buildRunningList(),
        ],
      ),
    );
  }

  Widget _buildRunningList() {
    final labels = [
      for (final p in _confirmedMm)
        scoreForRadius(math.sqrt(p.x * p.x + p.y * p.y), widget.face).toStringAsFixed(1),
    ];
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Уже добавлено', style: Theme.of(context).textTheme.labelMedium),
            const SizedBox(height: 4),
            Text(labels.join(', '), style: Theme.of(context).textTheme.bodyMedium),
          ],
        ),
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
              _confirmedMm.isEmpty
                  ? 'Сфотографируйте мишень камерой телефона и выберите снимок здесь — '
                      'приложение само в галерею не пишет и файл после разбора не хранит.'
                  : 'Можно выбрать ещё одно фото — или нажать «Готово» в шапке, если снимков достаточно.',
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

  Widget _buildReview(img.Image decoded) {
    return Column(
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
                        return _ReviewOverlay(
                          bytes: _bytes!,
                          displayScale: _displayScale,
                          center: _calibCenter!,
                          radius: _calibRadius,
                          candidates: _candidates,
                          addMode: _addMode,
                          onCalibrationChanged: (c, r) => setState(() {
                            _calibCenter = c;
                            _calibRadius = r;
                          }),
                          onCandidateMoved: (i, p) => setState(() => _candidates[i] = p),
                          onCandidateRemoved: (i) => setState(() => _candidates.removeAt(i)),
                          onCandidateAdded: (p) => setState(() {
                            _candidates.add(p);
                            _addMode = false;
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
            'Круг подогнан автоматически — при необходимости сдвиньте центр или '
            'потяните за край. Точки — найденные пробоины: перетащите, чтобы '
            'совместить с фактическим отверстием, или снимите лишнюю.',
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
                child: OutlinedButton.icon(
                  onPressed: _busy ? null : () => setState(() => _addMode = !_addMode),
                  icon: Icon(_addMode ? Icons.close : Icons.add_location_alt_outlined),
                  label: Text(_addMode ? 'Отмена' : 'Точка'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton(
                  onPressed: _busy ? null : _runDetection,
                  child: const Text('Найти снова'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                flex: 2,
                child: FilledButton(
                  onPressed: _busy || _candidates.isEmpty ? null : _confirmPhoto,
                  child: _busy
                      ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                      : Text('Подтвердить (${_candidates.length})'),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Фото + перетаскиваемый круг калибровки + точки-кандидаты поверх него.
/// Координаты хранятся в системе ИСХОДНОГО фото — виджет сам переводит
/// экранные жесты через `displayScale`, наружу всегда уходят "настоящие"
/// пиксели.
class _ReviewOverlay extends StatelessWidget {
  final Uint8List bytes;
  final double displayScale;
  final Offset center;
  final double radius;
  final List<Offset> candidates;
  final bool addMode;
  final void Function(Offset center, double radius) onCalibrationChanged;
  final void Function(int index, Offset newPos) onCandidateMoved;
  final void Function(int index) onCandidateRemoved;
  final void Function(Offset pos) onCandidateAdded;

  const _ReviewOverlay({
    required this.bytes,
    required this.displayScale,
    required this.center,
    required this.radius,
    required this.candidates,
    required this.addMode,
    required this.onCalibrationChanged,
    required this.onCandidateMoved,
    required this.onCandidateRemoved,
    required this.onCandidateAdded,
  });

  static const double _handleHitRadius = 24;
  static const double _dotRadius = 12;

  @override
  Widget build(BuildContext context) {
    final displayCenter = center * displayScale;
    final displayRadius = radius * displayScale;

    return Stack(
      fit: StackFit.expand,
      children: [
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapUp: addMode ? (details) => onCandidateAdded(details.localPosition / displayScale) : null,
          onPanUpdate: addMode
              ? null
              : (details) {
                  final local = details.localPosition;
                  final distFromEdge = (local - displayCenter).distance - displayRadius;
                  if (distFromEdge.abs() <= _handleHitRadius) {
                    final newRadius = (local - displayCenter).distance / displayScale;
                    onCalibrationChanged(center, newRadius.clamp(10, 5000));
                  } else {
                    onCalibrationChanged(center + details.delta / displayScale, radius);
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
        ),
        for (var i = 0; i < candidates.length; i++)
          Positioned(
            left: candidates[i].dx * displayScale - _dotRadius,
            top: candidates[i].dy * displayScale - _dotRadius,
            width: _dotRadius * 2,
            height: _dotRadius * 2,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => onCandidateRemoved(i),
              onPanUpdate: (details) => onCandidateMoved(
                i,
                candidates[i] + details.delta / displayScale,
              ),
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.redAccent.withValues(alpha: 0.85),
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white, width: 2),
                ),
              ),
            ),
          ),
      ],
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
