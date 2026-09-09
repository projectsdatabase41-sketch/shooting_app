import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:sensors_plus/sensors_plus.dart';

import '../logic/shot_photo_detection.dart';
import '../models/target_face.dart';
import '../services/shot_photo_service.dart';

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

  // ---- Индикатор "держите камеру перпендикулярно мишени" (пункт 5) ----
  //
  // Съёмка под углом — главная причина, по которой круглая мишень на
  // фото становится эллипсом и калибровочный круг потом не совпадает с
  // её настоящей формой (жалоба пользователя). Раз это заранее видно по
  // тому, как наклонён телефон, дешевле подсказать на месте съёмки, чем
  // потом бороться с перспективой на готовом фото.
  //
  // Ось Y акселерометра (стандарт Android/iOS) смотрит к верху экрана, Z —
  // из экрана наружу. У телефона, что держат строго вертикально перед
  // собой (камера смотрит горизонтально в мишень), сила тяжести целиком
  // ложится на Y (≈ +9.81), а X/Z ≈ 0. Отклонение по X — крен (кадр
  // заваливается набок), по Z — тангаж (камера смотрит вверх/вниз, из-за
  // чего круг мишени и превращается в эллипс). Сглаживаем экспоненциально
  // (коэффициент 0.2) — иначе точка индикатора дрожит на каждом чихе
  // датчика.
  double _gravX = 0;
  double _gravZ = 0;
  DateTime _lastTiltUiUpdate = DateTime.fromMillisecondsSinceEpoch(0);

  /// Пришло ли хоть одно показание датчика. Пока false, точка индикатора
  /// НЕ должна выглядеть "ровно" (координаты по умолчанию (0,0) иначе
  /// неотличимы от настоящего уровня) — без этого разбитый/недоступный
  /// датчик и телефон, который прямо сейчас держат ровно, выглядели бы
  /// одинаково, и жалобу "акселерометр не работает" было бы невозможно
  /// отличить от "он просто держал телефон ровно".
  bool _tiltAvailable = false;

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
      // Индикатор уровня нужен на ОБЕИХ платформах — в отличие от
      // самого механизма автоспуска (см. класс), у которого веб и
      // Android идут разными путями.
      _startTiltSensor();
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

  // ==================== Индикатор уровня (обе платформы) ====================

  void _startTiltSensor() {
    try {
      _accelSub = accelerometerEventStream().listen(_onAccel, onError: (_) {});
    } catch (_) {
      // Датчика нет или доступ не дали — индикатор остаётся в нейтральном
      // положении (см. начальные значения _gravX/_gravZ), съёмке это не
      // мешает, просто подсказки не будет.
    }
  }

  // ==================== Веб: таймер ====================

  void _startWebCountdown() {
    _countdownTicker = Timer.periodic(_webTick, (_) => _onWebTick());
  }

  void _onAccel(AccelerometerEvent e) {
    _tiltAvailable = true;
    _gravX += (e.x - _gravX) * 0.2;
    _gravZ += (e.z - _gravZ) * 0.2;

    final magnitude = math.sqrt(e.x * e.x + e.y * e.y + e.z * e.z);
    _recentAccelMagnitudes.add(magnitude);
    if (_recentAccelMagnitudes.length > 12) _recentAccelMagnitudes.removeAt(0);
    var stableChanged = false;
    if (_recentAccelMagnitudes.length >= 4) {
      final mean = _recentAccelMagnitudes.reduce((a, b) => a + b) / _recentAccelMagnitudes.length;
      final variance = _recentAccelMagnitudes.map((m) => (m - mean) * (m - mean)).reduce((a, b) => a + b) /
          _recentAccelMagnitudes.length;
      final stable = math.sqrt(variance) < _shakeThreshold;
      if (stable != _webStable) {
        _webStable = stable;
        stableChanged = true;
      }
    }

    // Индикатор уровня перерисовывается по своему таймингу (~15 кадров в
    // секунду) — датчик шлёт события гораздо чаще, и вызывать setState на
    // каждое было бы лишней нагрузкой ради неразличимой на глаз разницы.
    final now = DateTime.now();
    if (stableChanged || now.difference(_lastTiltUiUpdate) >= const Duration(milliseconds: 66)) {
      _lastTiltUiUpdate = now;
      if (mounted) setState(() {});
    }
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

  double get _bullseyeToFaceRatio => widget.face.faceRadiusMm / widget.face.bullseyeRadiusMm;

  void _analyze(CameraImage image) {
    final gray = _grayFromYPlane(image);

    if (_lockedCenter == null) {
      final circle = detectTargetCircle(gray, bullseyeToFaceRatio: _bullseyeToFaceRatio);
      if (circle == null) {
        if (mounted) setState(() => _status = _Status.searchingTarget);
        return;
      }
      _lockedCenter = circle.center;
      // Уточнение по кольцам — только один раз, в момент фиксации
      // центра, а не на каждом кадре: точное сравнение с геометрией
      // всех 10 колец заметно тяжелее самой калибровки по контрасту.
      _lockedRadius = refineRadiusByRings(
        image: gray,
        center: circle.center,
        initialRadiusPx: circle.radiusPx,
        ringRadiiMm: widget.face.ringRadiiMm,
        faceRadiusMm: widget.face.faceRadiusMm,
      );
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
      final decoded = ShotPhotoService.decode(await file.readAsBytes());

      // Проверка "мишень вообще в кадре" — тем же детектором, что и
      // калибровка на следующем экране, но уже на полном снимке, а не
      // на маленькой сетке потока. На вебе без нее отсчёт снял бы что
      // угодно, лишь бы телефон не дрожал; для ручной кнопки (на любой
      // платформе) это тоже единственная проверка вообще — нажатие само
      // по себе не подтверждает, что в кадре мишень.
      final analyzed = ShotPhotoService.analyze(decoded);
      final found = detectTargetCircle(analyzed.image, bullseyeToFaceRatio: _bullseyeToFaceRatio);
      if (found == null) {
        await _resumeSearching();
        return;
      }

      final square = _cropToSquare(decoded);
      final bytes = Uint8List.fromList(img.encodeJpg(square, quality: 92));
      if (mounted) Navigator.of(context).pop(bytes);
    } catch (e) {
      if (mounted) {
        setState(() => _error = '$e');
        await _resumeSearching();
      }
    }
  }

  /// Мишень не подтвердилась на снятом кадре — не отдаём его наружу, а
  /// возвращаемся к поиску, как будто автоспуска не было.
  Future<void> _resumeSearching() async {
    if (!mounted) return;
    setState(() {
      _capturing = false;
      _status = _Status.searchingTarget;
    });
    // _capture() останавливал акселерометр перед снимком (см. выше) —
    // индикатор уровня без этого остался бы замороженным навсегда.
    _startTiltSensor();
    if (kIsWeb) {
      _webProgress = 0;
      _startWebCountdown();
    } else {
      _lockedCenter = null;
      _pendingCandidate = null;
      _stableFrames = 0;
      final controller = _controller;
      if (controller != null && !controller.value.isStreamingImages) {
        await controller.startImageStream(_onFrame);
      }
    }
  }

  /// Обрезка по центру до квадрата 1:1 — мишень круглая, лишние поля по
  /// длинной стороне кадра только мешают калибровке на следующем экране.
  img.Image _cropToSquare(img.Image src) {
    final side = math.min(src.width, src.height);
    final x = (src.width - side) ~/ 2;
    final y = (src.height - side) ~/ 2;
    return img.copyCrop(src, x: x, y: y, width: side, height: side);
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
                    // Чёрно-белое — тот же довод, что и у разбора фото
                    // из галереи: контраст читается лучше, чем на
                    // цветном превью, а снимает и анализирует
                    // приложение всё равно в градациях серого.
                    //
                    // Center + AspectRatio — иначе StackFit.expand задаёт
                    // ЖЁСТКИЕ constraints на весь экран, AspectRatio их
                    // игнорирует при жёстких ограничениях (растягивая
                    // картинку под экран целиком), а Center отдаёт
                    // ребёнку СВОБОДНЫЕ ограничения того же максимального
                    // размера — единственный способ сохранить реальное
                    // соотношение сторон камеры внутри Stack.expand
                    // (жалоба пользователя: превью растянуто по вертикали).
                    Center(
                      child: AspectRatio(
                        aspectRatio: controller.value.aspectRatio,
                        child: ColorFiltered(
                          colorFilter: const ColorFilter.matrix(<double>[
                            0.2126, 0.7152, 0.0722, 0, 0,
                            0.2126, 0.7152, 0.0722, 0, 0,
                            0.2126, 0.7152, 0.0722, 0, 0,
                            0, 0, 0, 1, 0,
                          ]),
                          child: CameraPreview(controller),
                        ),
                      ),
                    ),
                    // Круглая рамка — мишень круглая, целиться в круг
                    // удобнее, чем в квадрат (решение пользователя).
                    // Итоговый снимок по-прежнему обрезается до квадрата
                    // 1:1 (см. _cropToSquare) — меняется только сама
                    // подсказка на экране, не логика обрезки: круг
                    // вписан в тот же квадрат кадрирования, что и раньше.
                    Center(
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          final side = math.min(constraints.maxWidth, constraints.maxHeight);
                          return Container(
                            width: side,
                            height: side,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              border: Border.all(color: Colors.white54, width: 1.5),
                            ),
                          );
                        },
                      ),
                    ),
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
                      alignment: Alignment.bottomLeft,
                      child: Padding(
                        padding: const EdgeInsets.only(left: 16, bottom: 24),
                        child: _TiltLevelIndicator(gravX: _gravX, gravZ: _gravZ, available: _tiltAvailable),
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

/// Пузырьковый уровень: точка смещается от центра пропорционально
/// наклону телефона, зелёная — когда почти в центре. Ровно то самое
/// "визуальное подтверждение перпендикулярности", о котором просил
/// пользователь (пункт 5) — снимок под углом иначе превращает круглую
/// мишень в эллипс уже на фото, когда исправлять поздно.
class _TiltLevelIndicator extends StatelessWidget {
  final double gravX;
  final double gravZ;

  /// Пришло ли хоть одно показание акселерометра. Пока нет — точка
  /// СЕРАЯ и стоит в центре не потому, что телефон ровно, а потому что
  /// данных ещё/вообще нет: иначе "не работает" и "и так уже ровно"
  /// неотличимы на глаз (см. `_CameraScanScreenState._tiltAvailable`).
  final bool available;

  const _TiltLevelIndicator({required this.gravX, required this.gravZ, required this.available});

  static const double _size = 72;
  static const double _dotSize = 16;
  static const double _maxOffset = (_size - _dotSize) / 2;
  static const double _levelToleranceFraction = 0.25;

  @override
  Widget build(BuildContext context) {
    final dx = (gravX / 9.81).clamp(-1.0, 1.0) * _maxOffset;
    final dy = (gravZ / 9.81).clamp(-1.0, 1.0) * _maxOffset;
    final level = math.sqrt(dx * dx + dy * dy) <= _maxOffset * _levelToleranceFraction;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: _size,
          height: _size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: Colors.black.withValues(alpha: 0.35),
            border: Border.all(color: Colors.white54, width: 1.5),
          ),
          child: Stack(
            alignment: Alignment.center,
            children: [
              Container(
                width: _size * 0.35,
                height: _size * 0.35,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white30, width: 1),
                ),
              ),
              Transform.translate(
                offset: available ? Offset(dx, dy) : Offset.zero,
                child: Container(
                  width: _dotSize,
                  height: _dotSize,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: !available ? Colors.grey : (level ? Colors.greenAccent : Colors.amber),
                  ),
                ),
              ),
            ],
          ),
        ),
        if (!available) ...[
          const SizedBox(height: 4),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.55),
              borderRadius: BorderRadius.circular(6),
            ),
            child: const Text(
              'Датчик недоступен',
              style: TextStyle(color: Colors.white70, fontSize: 10),
            ),
          ),
        ],
      ],
    );
  }
}
