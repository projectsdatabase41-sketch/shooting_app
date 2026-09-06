import 'dart:async';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

import '../logic/shot_photo_detection.dart';
import '../models/target_face.dart';

/// Живая камера: наводим на мишень, приложение само находит пробоину и
/// делает снимок — решение пользователя предпочесть это статичному
/// выбору фото из галереи (доступно только на Android — см. pubspec.yaml).
///
/// Анализ идёт на маленькой уменьшенной копии живого кадра (яркостная
/// плоскость потока камеры, без цвета — она и так уже градации серого),
/// поэтому не нагружает поток предпросмотра. Экран решает только КОГДА
/// снять кадр; само итоговое фото после автоспуска проходит через тот же
/// точный разбор и ту же правку руками, что и фото из галереи — если
/// наводка была не идеальной, это не потеряно, а исправляется на
/// следующем экране.
class CameraScanScreen extends StatefulWidget {
  final TargetFace face;
  final List<PixelPoint> knownHolesMm;

  const CameraScanScreen({super.key, required this.face, required this.knownHolesMm});

  @override
  State<CameraScanScreen> createState() => _CameraScanScreenState();
}

enum _Status { searchingTarget, searchingHole, holding, capturing }

class _CameraScanScreenState extends State<CameraScanScreen> {
  CameraController? _controller;
  String? _error;
  _Status _status = _Status.searchingTarget;

  // Аналитическая сетка — фиксированный небольшой размер независимо от
  // разрешения потока, чтобы разбор каждого кадра стоил одинаково дёшево.
  static const int _gridSide = 240;

  bool _processing = false;
  DateTime _lastProcessed = DateTime.fromMillisecondsSinceEpoch(0);

  PixelPoint? _lockedCenter;
  double _lockedRadius = 0;
  PixelPoint? _pendingCandidate;
  int _stableFrames = 0;
  static const int _stableFramesNeeded = 4;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    try {
      final cameras = await availableCameras();
      final back = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );
      final controller = CameraController(
        back,
        ResolutionPreset.high,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.yuv420,
      );
      await controller.initialize();
      if (!mounted) {
        await controller.dispose();
        return;
      }
      setState(() => _controller = controller);
      await controller.startImageStream(_onFrame);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  @override
  void dispose() {
    final c = _controller;
    if (c != null) {
      if (c.value.isStreamingImages) c.stopImageStream();
      c.dispose();
    }
    super.dispose();
  }

  void _onFrame(CameraImage image) {
    if (_processing) return;
    final now = DateTime.now();
    if (now.difference(_lastProcessed) < const Duration(milliseconds: 300)) return;
    _processing = true;
    _lastProcessed = now;
    try {
      _analyze(image);
    } catch (_) {
      // Кадр камеры — best-effort подсказка автоспуска, не критичный
      // путь: разовый сбой разбора одного кадра не должен ронять поток.
    } finally {
      _processing = false;
    }
  }

  /// Строит маленькое изображение в градациях серого из Y-плоскости
  /// потока YUV420 — она и есть готовая яркость, без перевода в RGB.
  GrayImage _grayFromYPlane(CameraImage image) {
    final plane = image.planes.first;
    final srcW = image.width, srcH = image.height;
    final stride = plane.bytesPerRow;
    const side = _gridSide;
    final scale = side / (srcW < srcH ? srcW : srcH);
    final gw = (srcW * scale).round().clamp(8, 2000);
    final gh = (srcH * scale).round().clamp(8, 2000);
    final out = Uint8List(gw * gh);
    final bytes = plane.bytes;
    for (var y = 0; y < gh; y++) {
      final sy = (y / scale).floor().clamp(0, srcH - 1);
      final rowOff = sy * stride;
      for (var x = 0; x < gw; x++) {
        final sx = (x / scale).floor().clamp(0, srcW - 1);
        out[y * gw + x] = bytes[rowOff + sx];
      }
    }
    return GrayImage(gw, gh, out);
  }

  void _analyze(CameraImage image) {
    final gray = _grayFromYPlane(image);

    if (_lockedCenter == null) {
      final circle = detectTargetCircle(gray);
      if (circle == null) {
        if (mounted) setState(() => _status = _Status.searchingTarget);
        return;
      }
      _lockedCenter = circle.center;
      _lockedRadius = circle.radiusPx;
    }

    final center = _lockedCenter!;
    final caliberRadiusPx = _lockedRadius * (widget.face.caliberMm / 2) / widget.face.faceRadiusMm;
    final knownPx = [
      for (final mm in widget.knownHolesMm)
        PixelPoint(
          center.x + mm.x / widget.face.faceRadiusMm * _lockedRadius,
          center.y - mm.y / widget.face.faceRadiusMm * _lockedRadius,
        ),
    ];

    final candidates = findCandidateHoles(
      image: gray,
      center: center,
      radiusPx: _lockedRadius,
      caliberRadiusPx: caliberRadiusPx,
      knownHolesPx: knownPx,
    );

    if (candidates.isEmpty) {
      _pendingCandidate = null;
      _stableFrames = 0;
      if (mounted) setState(() => _status = _Status.searchingHole);
      return;
    }

    final top = candidates.first;
    final prev = _pendingCandidate;
    final tolerance = caliberRadiusPx * 0.8;
    final matches = prev != null &&
        (top.center.x - prev.x).abs() < tolerance &&
        (top.center.y - prev.y).abs() < tolerance;
    _pendingCandidate = top.center;
    _stableFrames = matches ? _stableFrames + 1 : 1;

    if (mounted) setState(() => _status = _Status.holding);

    if (_stableFrames >= _stableFramesNeeded) {
      _capture();
    }
  }

  Future<void> _capture() async {
    final controller = _controller;
    if (controller == null || _status == _Status.capturing) return;
    setState(() => _status = _Status.capturing);
    try {
      if (controller.value.isStreamingImages) {
        await controller.stopImageStream();
      }
      final file = await controller.takePicture();
      final bytes = await file.readAsBytes();
      if (mounted) Navigator.of(context).pop(bytes);
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = '$e';
          _status = _Status.searchingTarget;
        });
      }
    }
  }

  Future<void> _captureManually() async {
    _stableFrames = _stableFramesNeeded;
    await _capture();
  }

  String get _statusText => switch (_status) {
        _Status.searchingTarget => 'Наведите камеру на мишень',
        _Status.searchingHole => 'Мишень найдена — ищу пробоину',
        _Status.holding => 'Пробоина найдена — держите ровно…',
        _Status.capturing => 'Снимаю…',
      };

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text('Наведите на мишень'),
      ),
      body: _error != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(_error!, style: const TextStyle(color: Colors.white), textAlign: TextAlign.center),
              ),
            )
          : controller == null || !controller.value.isInitialized
              ? const Center(child: CircularProgressIndicator())
              : Stack(
                  fit: StackFit.expand,
                  children: [
                    CameraPreview(controller),
                    Align(
                      alignment: Alignment.topCenter,
                      child: Padding(
                        padding: const EdgeInsets.only(top: 16),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.55),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Text(_statusText, style: const TextStyle(color: Colors.white)),
                        ),
                      ),
                    ),
                    Align(
                      alignment: Alignment.bottomCenter,
                      child: Padding(
                        padding: const EdgeInsets.only(bottom: 24),
                        child: FloatingActionButton(
                          onPressed: _status == _Status.capturing ? null : _captureManually,
                          child: const Icon(Icons.camera_alt),
                        ),
                      ),
                    ),
                  ],
                ),
    );
  }
}
