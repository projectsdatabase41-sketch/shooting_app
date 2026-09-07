import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:sensors_plus/sensors_plus.dart';

import '../logic/shot_photo_detection.dart';
import '../models/target_face.dart';

/// Живая камера: наводим на мишень, приложение само делает снимок.
///
/// Два РАЗНЫХ механизма решают, когда снять кадр — в зависимости от
/// платформы:
///
/// - **Android**: анализ живого потока (`startImageStream`) — та же
///   яркостная плоскость YUV420, что и раньше: находит круг мишени и
///   саму пробоину по пикселям, снимает, как только несколько кадров
///   подряд видят одну и ту же новую пробоину на месте.
/// - **Веб**: `camera_web` в принципе не отдаёт кадры потока
///   (`startImageStream` там — `UnimplementedError`, только готовые
///   снимки через `takePicture()`), поэтому "трясётся ли картинка" по
///   пикселям не определить. Вместо этого — обратный отсчёт 2 секунды с
///   анимацией плюс акселерометр телефона: пока телефон дрожит, отсчёт
///   не продвигается (и визуально "сбрасывается"), как только дрожь
///   утихла — отсчёт идёт плавно до конца и снимает кадр сам. Если
///   датчика нет (например, ноутбук без акселерометра), отсчёт идёт
///   обычным таймером без проверки — это осознанный запасной вариант, а
///   не баг.
///
/// В обоих случаях итоговое фото после автоспуска проходит через тот же
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
  bool _capturing = false;

  // ---- Android: анализ потока по пикселям ----

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

  // ---- Веб: таймер + акселерометр ----

  StreamSubscription<AccelerometerEvent>? _accelSub;
  final List<double> _recentAccelMagnitudes = [];
  bool _webStable = true; // нет датчика — считаем неподвижным (запасной путь)
  Timer? _countdownTicker;
  double _webProgress = 0; // 0..1 за _webCountdown
  static const Duration _webCountdown = Duration(seconds: 2);
  static const Duration _webTick = Duration(milliseconds: 40);
  static const double _shakeThreshold = 0.6; // м/с², стандартное отклонение модуля ускорения

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
        imageFormatGroup: kIsWeb ? null : ImageFormatGroup.yuv420,
      );
      await controller.initialize();
      if (!mounted) {
        await controller.dispose();
        return;
      }
      setState(() => _controller = controller);
      if (kIsWeb) {
        _startWebCountdown();
      } else {
        await controller.startImageStream(_onFrame);
      }
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  @override
  void dispose() {
    _accelSub?.cancel();
    _countdownTicker?.cancel();
    final c = _controller;
    if (c != null) {
      if (c.value.isStreamingImages) c.stopImageStream();
      c.dispose();
    }
    super.dispose();
  }

  // ==================== Веб: таймер + акселерометр ====================

  void _startWebCountdown() {
    try {
      _accelSub = accelerometerEventStream().listen(_onAccel, onError: (_) {});
    } catch (_) {
      // Датчика нет или доступ не дали — отсчёт просто идёт без проверки.
    }
    _countdownTicker = Timer.periodic(_webTick, (_) => _onWebTick());
  }

  void _onAccel(AccelerometerEvent e) {
    final magnitude = math.sqrt(e.x * e.x + e.y * e.y + e.z * e.z);
    _recentAccelMagnitudes.add(magnitude);
    if (_recentAccelMagnitudes.length > 12) _recentAccelMagnitudes.removeAt(0);
    if (_recentAccelMagnitudes.length < 4) return;
    final mean = _recentAccelMagnitudes.reduce((a, b) => a + b) / _recentAccelMagnitudes.length;
    final variance = _recentAccelMagnitudes.map((m) => (m - mean) * (m - mean)).reduce((a, b) => a + b) /
        _recentAccelMagnitudes.length;
    final stable = math.sqrt(variance) < _shakeThreshold;
    if (stable != _webStable && mounted) setState(() => _webStable = stable);
  }

  void _onWebTick() {
    if (_capturing || !mounted) return;
    final step = _webTick.inMilliseconds / _webCountdown.inMilliseconds;
    setState(() {
      if (_webStable) {
        _webProgress = math.min(1, _webProgress + step);
        if (_webProgress >= 1) _capture();
      } else {
        // Сброс быстрее набора — одно резкое движение должно заметно
        // откатить отсчёт назад, а не просто чуть притормозить его.
        _webProgress = math.max(0, _webProgress - step * 3);
      }
    });
  }

  // ==================== Android: анализ потока по пикселям ====================

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

  // ==================== Общее: сам снимок ====================

  Future<void> _capture() async {
    final controller = _controller;
    if (controller == null || _capturing) return;
    setState(() {
      _capturing = true;
      _status = _Status.capturing;
    });
    try {
      if (controller.value.isStreamingImages) {
        await controller.stopImageStream();
      }
      _countdownTicker?.cancel();
      await _accelSub?.cancel();
      final file = await controller.takePicture();
      final bytes = await file.readAsBytes();
      if (mounted) Navigator.of(context).pop(bytes);
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = '$e';
          _status = _Status.searchingTarget;
          _capturing = false;
        });
        if (kIsWeb) _startWebCountdown();
      }
    }
  }

  Future<void> _captureManually() async {
    _stableFrames = _stableFramesNeeded;
    await _capture();
  }

  String get _statusText {
    if (kIsWeb) {
      if (_capturing) return 'Снимаю…';
      return _webStable ? 'Держите ровно…' : 'Не двигайте телефон';
    }
    return switch (_status) {
      _Status.searchingTarget => 'Наведите камеру на мишень',
      _Status.searchingHole => 'Мишень найдена — ищу пробоину',
      _Status.holding => 'Пробоина найдена — держите ровно…',
      _Status.capturing => 'Снимаю…',
    };
  }

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
                    if (kIsWeb)
                      Align(
                        alignment: Alignment.center,
                        // Прогресс обновляется тикером каждые 40мс через
                        // setState — этого достаточно для плавной на вид
                        // анимации без дополнительной обёртки.
                        child: SizedBox(
                          width: 84,
                          height: 84,
                          child: CircularProgressIndicator(
                            value: _webProgress,
                            strokeWidth: 5,
                            backgroundColor: Colors.white24,
                            valueColor: AlwaysStoppedAnimation(_webStable ? Colors.greenAccent : Colors.amber),
                          ),
                        ),
                      ),
                    Align(
                      alignment: Alignment.bottomCenter,
                      child: Padding(
                        padding: const EdgeInsets.only(bottom: 24),
                        child: FloatingActionButton(
                          onPressed: _capturing ? null : _captureManually,
                          child: const Icon(Icons.camera_alt),
                        ),
                      ),
                    ),
                  ],
                ),
    );
  }
}
