import 'dart:math' as math;
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show compute, defaultTargetPlatform, kIsWeb, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:provider/provider.dart';

import '../local_ai/local_ai.dart';
import '../local_ai/local_ai_catalog.dart';
import '../local_ai/local_vision.dart';
import '../logic/scoring.dart';
import '../logic/shot_photo_detection.dart';
import '../models/target_face.dart';
import '../services/ai_settings.dart';
import '../services/shot_photo_service.dart';
import '../state/app_data_store.dart';
import 'camera_scan_screen.dart';
import 'shot_review_screen.dart';
import '../i18n/i18n.dart';

/// Функции для `compute()` — обязаны быть верхнеуровневыми: изолят видит
/// только сам код функции и переданный ей аргумент, никаких замыканий.
List<HoleCandidate> _detectInIsolate(_DetectArgs args) {
  return findCandidateHoles(
    image: args.image,
    center: args.center,
    radiusPx: args.radiusPx,
    radiusYPx: args.radiusYPx,
    angleRad: args.angleRad,
    caliberRadiusPx: args.caliberRadiusPx,
    knownHolesPx: args.knownHolesPx,
    ringRadiiMm: args.ringRadiiMm,
    faceRadiusMm: args.faceRadiusMm,
  );
}

({PixelPoint center, double radiusPx})? _detectCircleInIsolate(_CalibArgs args) {
  final auto = detectTargetCircle(args.image, bullseyeToFaceRatio: args.bullseyeToFaceRatio);
  if (auto == null) return null;
  // Уточнение по печатным кольцам — поверх уже найденного центра и
  // грубого радиуса: точные, заранее известные расстояния до всех 10
  // колец надёжнее любой эвристики по форме пятна или контрасту с
  // фоном (см. комментарий к refineRadiusByRings).
  final refined = refineRadiusByRings(
    image: args.image,
    center: auto.center,
    initialRadiusPx: auto.radiusPx,
    ringRadiiMm: args.ringRadiiMm,
    faceRadiusMm: args.faceRadiusMm,
  );
  return (center: auto.center, radiusPx: refined);
}

class _CalibArgs {
  final GrayImage image;
  final double bullseyeToFaceRatio;
  final List<double> ringRadiiMm;
  final double faceRadiusMm;
  const _CalibArgs({
    required this.image,
    required this.bullseyeToFaceRatio,
    required this.ringRadiiMm,
    required this.faceRadiusMm,
  });
}

class _DetectArgs {
  final GrayImage image;
  final PixelPoint center;
  final double radiusPx;
  final double radiusYPx;
  final double angleRad;
  final double caliberRadiusPx;
  final List<PixelPoint> knownHolesPx;
  final List<double> ringRadiiMm;
  final double faceRadiusMm;
  const _DetectArgs({
    required this.image,
    required this.center,
    required this.radiusPx,
    required this.radiusYPx,
    required this.angleRad,
    required this.caliberRadiusPx,
    required this.knownHolesPx,
    required this.ringRadiiMm,
    required this.faceRadiusMm,
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

class _PhotoScanScreenState extends State<PhotoScanScreen> with WidgetsBindingObserver {
  /// ИИ смотрит на фото — «назад» и сворачивание прерывают, а не уходят.
  bool _visionRunning = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (_visionRunning) LocalAi.instance.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_visionRunning && (state == AppLifecycleState.paused || state == AppLifecycleState.hidden)) {
      LocalAi.instance.cancel();
    }
  }

  Uint8List? _bytes;
  img.Image? _decoded;
  String? _error;
  bool _busy = false;
  bool _addMode = false;

  // Калибровка — в координатах ИСХОДНОГО (не отображаемого) фото.
  // Эллипс, а не круг (пункты 1 и 3 списка правок): фото, снятое не
  // строго перпендикулярно мишени, превращает её круглый контур в
  // эллипс, и калибровка должна уметь повторить эту же форму, а не
  // упрямо подгонять круг под то, что кругом уже не выглядит.
  // `_calibRy == _calibRx` и `_calibAngle == 0` — обычный круг, ничего
  // не меняющий для перпендикулярных снимков.
  Offset? _calibCenter;
  double _calibRx = 0;
  double _calibRy = 0;
  double _calibAngle = 0;

  // Кандидаты текущего фото — тоже в координатах исходного фото.
  List<Offset> _candidates = [];

  /// Когда была вручную добавлена последняя точка (режим "+") — нужно,
  /// чтобы отличить настоящий тап от начала щипка двумя пальцами: если
  /// второй палец касается экрана в течение этого окна после того, как
  /// первый успел зарегистрироваться тапом и создать точку, это не
  /// добавление, а начало масштабирования, и точку нужно откатить
  /// (пункт 5 списка правок).
  DateTime? _lastManualAddAt;
  static const _pinchCancelWindow = Duration(milliseconds: 500);

  void _cancelAccidentalTap() {
    final at = _lastManualAddAt;
    if (at == null || _candidates.isEmpty) return;
    if (DateTime.now().difference(at) > _pinchCancelWindow) return;
    setState(() {
      _candidates.removeLast();
      _lastManualAddAt = null;
    });
  }

  // Накопленный список подтверждённых пробоин (across фото), в мм.
  final List<PixelPoint> _confirmedMm = [];

  /// Сколько выстрелов сделано в это фото — сколько угодно мишеней,
  /// поле одно и то же. `null` — авто: сколько пробоин нашли/оставили,
  /// столько и есть. Если пробоин меньше указанного числа (несколько
  /// легло в одну и ту же дырку — по фото их не различить), при
  /// подтверждении недостающие достраиваются В ТОЙ ЖЕ точке (решение
  /// пользователя: "выбрав 2 выстрела, просто покажет 2 выстрела в
  /// одной точке").
  int? _expectedCount;

  static const List<int> _countChoices = [1, 2, 3, 4, 5, 6, 8, 10];

  double _displayScale = 1; // display px = natural px * _displayScale

  List<PixelPoint> get _allKnownMm => [...widget.knownHolesMm, ..._confirmedMm];

  /// Живая камера — Android-сборка и веб (там `camera_web` умеет только
  /// открыть превью и снять кадр, без анализа потока — см.
  /// camera_scan_screen.dart, там же таймер+акселерометр вместо
  /// разбора пикселей). На Windows desktop `camera` не работает вовсе —
  /// остаётся привычный выбор файла.
  bool get _cameraAvailable => kIsWeb || defaultTargetPlatform == TargetPlatform.android;

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
      if (bytes == null) throw ShotPhotoException(tr('Не удалось прочитать файл'));
      await _loadPhoto(bytes);
    } catch (e) {
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openCamera() async {
    final bytes = await Navigator.of(context).push<Uint8List>(
      MaterialPageRoute(
        builder: (_) => CameraScanScreen(face: widget.face, knownHolesMm: _allKnownMm),
      ),
    );
    if (bytes == null || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await _loadPhoto(bytes);
    } catch (e) {
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _loadPhoto(Uint8List bytes) async {
    final decoded = ShotPhotoService.decode(bytes);
    final analyzed = ShotPhotoService.analyze(decoded);
    final autoCircle = await compute(
      _detectCircleInIsolate,
      _CalibArgs(
        image: analyzed.image,
        bullseyeToFaceRatio: widget.face.faceRadiusMm / widget.face.bullseyeRadiusMm,
        ringRadiiMm: widget.face.ringRadiiMm,
        faceRadiusMm: widget.face.faceRadiusMm,
      ),
    );

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
      _calibRx = radius;
      _calibRy = radius;
      _calibAngle = 0;
      _candidates = [];
    });
    await _runDetection();
  }

  Future<void> _runDetection() async {
    final decoded = _decoded;
    final center = _calibCenter;
    if (decoded == null || center == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    // Режим разработчика + скачанная модель «со зрением» — пробоины ищет она
    // (обычный алгоритм путает цифры колец с пробоинами). Сбой — алгоритм.
    final vision = await LocalVision.active(AiSettings(context.read<AppDataStore>().db));
    if (vision != null) {
      setState(() => _visionRunning = true);
      try {
        await _runVision(vision, decoded, center);
        return;
      } on LocalAiCancelled {
        // Прервали — остаёмся на фото с кругом, дальше вручную.
        if (mounted) {
          setState(() {
            _busy = false;
            _error = tr('Распознавание прервано. Можно поставить точки вручную или снять новое фото.');
          });
        }
        return;
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text(tr('ИИ-зрение не сработало ({e}) — ищет обычный алгоритм', {'e': e}))));
        }
      } finally {
        if (mounted) setState(() => _visionRunning = false);
      }
    }
    try {
      final analyzed = ShotPhotoService.analyze(decoded);
      final s = analyzed.scale;
      final scaledCenter = PixelPoint(center.dx * s, center.dy * s);
      final scaledRx = _calibRx * s;
      final scaledRy = _calibRy * s;
      // Калибр и окно ожидаемого размера пробоины считаем по СРЕДНЕМУ
      // радиусу эллипса — при умеренном наклоне (а калибровка эллипсом
      // рассчитана именно на умеренный, не на настоящую трапецию) разница
      // между полуосями небольшая, и отдельный калибр под каждую ось
      // усложнил бы формулы без заметной пользы.
      final avgRadiusPx = (scaledRx + scaledRy) / 2;
      final caliberRadiusPx = avgRadiusPx * (widget.face.caliberMm / 2) / widget.face.faceRadiusMm;
      final knownPx = [
        for (final mm in _allKnownMm)
          mmToPixelEllipse(mm, scaledCenter, scaledRx, scaledRy, _calibAngle, widget.face.faceRadiusMm),
      ];

      final candidates = await compute(
        _detectInIsolate,
        _DetectArgs(
          image: analyzed.image,
          center: scaledCenter,
          radiusPx: scaledRx,
          radiusYPx: scaledRy,
          angleRad: _calibAngle,
          caliberRadiusPx: caliberRadiusPx,
          knownHolesPx: knownPx,
          ringRadiiMm: widget.face.ringRadiiMm,
          faceRadiusMm: widget.face.faceRadiusMm,
        ),
      );

      if (!mounted) return;
      setState(() {
        _busy = false;
        _candidates = [for (final c in candidates) Offset(c.center.x / s, c.center.y / s)];
        if (_candidates.isEmpty) {
          _error = tr('Пробоин не нашли — либо на фото их не видно, либо круг откалиброван неточно. Можно подровнять круг или добавить точку вручную кнопкой ниже.');
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

  /// Квадрат вокруг откалиброванного круга → модель → точки обратно в
  /// пиксели исходного фото. Вне круга мишени (с запасом 5%) — отбрасываем.
  Future<void> _runVision(LocalModelInfo m, img.Image decoded, Offset center) async {
    final half = math.max(_calibRx, _calibRy) * 1.1;
    final x0 = (center.dx - half).clamp(0, decoded.width - 1).floor();
    final y0 = (center.dy - half).clamp(0, decoded.height - 1).floor();
    final x1 = (center.dx + half).clamp(1, decoded.width).ceil();
    final y1 = (center.dy + half).clamp(1, decoded.height).ceil();
    final crop = img.copyCrop(decoded, x: x0, y: y0, width: x1 - x0, height: y1 - y0);
    final square = img.copyResize(crop, width: LocalVision.side, height: LocalVision.side);
    final jpeg = Uint8List.fromList(img.encodeJpg(square, quality: 90));
    final points = await LocalVision.findHoles(m, jpeg);
    final sx = (x1 - x0) / LocalVision.side, sy = (y1 - y0) / LocalVision.side;
    final maxR = math.max(_calibRx, _calibRy) * 1.05;
    if (!mounted) return;
    setState(() {
      _busy = false;
      _candidates = [
        for (final p in points)
          if ((Offset(x0 + p.dx * sx, y0 + p.dy * sy) - center).distance <= maxR)
            Offset(x0 + p.dx * sx, y0 + p.dy * sy),
      ];
      if (_candidates.isEmpty) {
        _error = tr('ИИ не нашёл пробоин. Можно подровнять круг или добавить точку вручную кнопкой ниже.');
      }
    });
    if (_candidates.isNotEmpty) await _reviewOnTarget();
  }

  /// Выстрелы от ИИ — сразу на схеме мишени, без подгонки круга: круг уже
  /// найден автоматически. «ОК» — в тренировку; «Отмена» — остаёмся на
  /// фото с кругом и точками, как в обычном режиме (поправить вручную).
  Future<void> _reviewOnTarget() async {
    final result = await Navigator.of(context).push<List<PixelPoint>>(MaterialPageRoute(
      builder: (_) => ShotReviewScreen(face: widget.face, shotsMm: _candidatesToConfirm.map(_toMm).toList()),
    ));
    if (result == null || !mounted) return;
    _confirmedMm.addAll(result);
    _finish();
  }

  PixelPoint _toMm(Offset px) => pixelToMmEllipse(
        PixelPoint(px.dx, px.dy),
        PixelPoint(_calibCenter!.dx, _calibCenter!.dy),
        _calibRx,
        _calibRy,
        _calibAngle,
        widget.face.faceRadiusMm,
      );

  /// Кандидаты, подогнанные под заданное число выстрелов (см.
  /// `_expectedCount`) — это ЖЁСТКОЕ число, не подсказка: пользователь
  /// точно знает, сколько раз стрелял, а автоматика по фото — нет.
  /// Меньше найденных, чем указано, — недостающие достраиваются в той
  /// же точке (несколько лечь в одну дырку по фото не различить).
  /// Больше найденных — оставляем только первые (самые уверенные:
  /// `findCandidateHoles` возвращает их отсортированными по круглости,
  /// а марок, добавленных руками, в начале списка не бывает).
  List<Offset> get _candidatesToConfirm {
    final count = _expectedCount;
    if (count == null) return _candidates;
    if (_candidates.length > count) return _candidates.take(count).toList();
    if (_candidates.isEmpty || _candidates.length == count) return _candidates;
    return [..._candidates, for (var i = _candidates.length; i < count; i++) _candidates.last];
  }

  void _confirmPhoto() {
    setState(() {
      _confirmedMm.addAll(_candidatesToConfirm.map(_toMm));
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
    return PopScope(
      canPop: !_visionRunning,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) LocalAi.instance.cancel();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(_visionRunning ? tr('ИИ смотрит… (назад — прервать)') : tr('Фото мишени')),
          actions: [
            if (_confirmedMm.isNotEmpty)
              TextButton(
                onPressed: _finish,
                child: Text(tr('Готово ({length})', {'length': _confirmedMm.length}), style: const TextStyle(color: Colors.white)),
              ),
          ],
        ),
        body: Column(
          children: [
            Expanded(child: decoded == null ? _buildPickPrompt() : _buildReview(decoded)),
            if (_confirmedMm.isNotEmpty) _buildRunningList(),
          ],
        ),
      ),
    );
  }

  Widget _buildRunningList() {
    final labels = [
      for (final p in _confirmedMm) scoreForRadius(math.sqrt(p.x * p.x + p.y * p.y), widget.face).toStringAsFixed(1),
    ];
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(tr('Уже добавлено'), style: Theme.of(context).textTheme.labelMedium),
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
                  ? (_cameraAvailable
                      ? tr('Наведите камеру на мишень — приложение само найдёт пробоину и снимет кадр. Файл нигде не сохраняется и после разбора не хранится.')
                      : tr('Сфотографируйте мишень и выберите снимок здесь — приложение само в галерею не пишет и файл после разбора не хранит.'))
                  : tr('Можно снять ещё одно фото — или нажать «Готово» в шапке, если снимков достаточно.'),
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 16),
            // Сколько выстрелов на этом снимке — до съёмки, а не после:
            // число нужно ДЛЯ разбора найденных пробоин (см.
            // _candidatesToConfirm), а не для самой фотографии.
            _buildCountSelector(),
            const SizedBox(height: 8),
            if (_cameraAvailable) ...[
              FilledButton.icon(
                onPressed: _busy ? null : _openCamera,
                icon: _busy
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.camera_alt_outlined),
                label: Text(tr('Через камеру')),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: _busy ? null : _pick,
                icon: const Icon(Icons.image_outlined),
                label: Text(tr('Выбрать фото')),
              ),
            ] else
              FilledButton.icon(
                onPressed: _busy ? null : _pick,
                icon: _busy
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.image_outlined),
                label: Text(tr('Выбрать фото')),
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
                          radiusX: _calibRx,
                          radiusY: _calibRy,
                          angle: _calibAngle,
                          // Радиус пробоины в тех же пикселях фото, что и
                          // калибровка (по среднему радиусу эллипса) — от
                          // него и масштабируется маркер, чтобы на экране
                          // он был не крупнее настоящего отверстия
                          // (решение пользователя, иначе точную подгонку
                          // неудобно делать).
                          holeRadiusPx:
                              (_calibRx + _calibRy) / 2 * widget.face.caliberRadiusMm / widget.face.faceRadiusMm,
                          candidates: _candidates,
                          addMode: _addMode,
                          onCalibrationChanged: (c, rx, ry, angle) => setState(() {
                            _calibCenter = c;
                            _calibRx = rx;
                            _calibRy = ry;
                            _calibAngle = angle;
                          }),
                          onCandidateMoved: (i, p) => setState(() => _candidates[i] = p),
                          onCandidateRemoved: (i) => setState(() => _candidates.removeAt(i)),
                          onCandidateAdded: (p) => setState(() {
                            _candidates.add(p);
                            _addMode = false;
                            _lastManualAddAt = DateTime.now();
                          }),
                          onPinchStart: _cancelAccidentalTap,
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
            tr('Контур подогнан автоматически — сдвиньте центр, потяните за один из двух маркеров на краю, чтобы растянуть контур в овал под углом съёмки, если фото снято не строго анфас. Точки — найденные пробоины: перетащите, чтобы совместить с фактическим отверстием, или снимите лишнюю.'),
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
                  label: Text(_addMode ? tr('Отмена') : tr('Точка')),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton(
                  onPressed: _busy ? null : _retakePhoto,
                  child: Text(tr('Новое фото')),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                flex: 2,
                child: FilledButton(
                  onPressed: _busy || _candidates.isEmpty ? null : _confirmPhoto,
                  child: _busy
                      ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                      : Text(tr('Подтвердить ({length})', {'length': _candidatesToConfirm.length})),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// Отказаться от текущего фото и сразу переснять — камера/выбор файла
  /// открывается заново, как в первый раз (решение пользователя: кнопка
  /// повторного поиска на том же снимке была почти бесполезна, если
  /// сам снимок неудачный).
  Future<void> _retakePhoto() => _cameraAvailable ? _openCamera() : _pick();

  Widget _buildCountSelector() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Row(
        children: [
          Text(tr('Выстрелов:'), style: Theme.of(context).textTheme.labelMedium),
          const SizedBox(width: 8),
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  ChoiceChip(
                    label: Text(tr('Авто')),
                    selected: _expectedCount == null,
                    onSelected: (_) => setState(() => _expectedCount = null),
                  ),
                  for (final n in _countChoices) ...[
                    const SizedBox(width: 6),
                    ChoiceChip(
                      label: Text('$n'),
                      selected: _expectedCount == n,
                      onSelected: (_) => setState(() => _expectedCount = n),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
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
  final double radiusX;
  final double radiusY;
  final double angle;
  final double holeRadiusPx;
  final List<Offset> candidates;
  final bool addMode;
  final void Function(Offset center, double radiusX, double radiusY, double angle) onCalibrationChanged;
  final void Function(int index, Offset newPos) onCandidateMoved;
  final void Function(int index) onCandidateRemoved;
  final void Function(Offset pos) onCandidateAdded;

  /// Начался жест с ДВУМЯ и более пальцами (масштабирование) — пункт 5
  /// списка правок: если секунду назад в режиме добавления палец успел
  /// зарегистрироваться как одиночный тап и создать пробоину, а это на
  /// самом деле было начало щипка (второй палец просто чуть опоздал),
  /// вызывающий код откатывает ту пробоину.
  final VoidCallback onPinchStart;

  const _ReviewOverlay({
    required this.bytes,
    required this.displayScale,
    required this.center,
    required this.radiusX,
    required this.radiusY,
    required this.angle,
    required this.holeRadiusPx,
    required this.candidates,
    required this.addMode,
    required this.onCalibrationChanged,
    required this.onCandidateMoved,
    required this.onCandidateRemoved,
    required this.onCandidateAdded,
    required this.onPinchStart,
  });

  static const double _handleHitRadius = 24;
  // Хитбокс пальца не меньше этого радиуса, даже если настоящее отверстие
  // на экране мельче — иначе по мелкому калибру (4.5мм воздушки) не
  // попасть пальцем. Сам КРУЖОК рисуется реального размера (см. build).
  static const double _minTapRadius = 16;

  @override
  Widget build(BuildContext context) {
    final displayCenter = center * displayScale;
    final displayRx = radiusX * displayScale;
    final displayRy = radiusY * displayScale;
    // Два независимых маркера на краю эллипса — один растягивает/поворачивает
    // ось radiusX, второй только меняет длину radiusY (угол задаёт
    // ЕДИНСТВЕННО первый маркер, чтобы оба не спорили за поворот разом).
    final handleA = displayCenter + Offset(displayRx * math.cos(angle), displayRx * math.sin(angle));
    final perp = Offset(-math.sin(angle), math.cos(angle));
    final handleB = displayCenter + perp * displayRy;

    // panEnabled: false — одним пальцем управляют калибровка/маркеры,
    // как и раньше; InteractiveViewer перехватывает только жест минимум
    // с ДВУМЯ пальцами (масштаб), без обычного панорамирования одним
    // пальцем поверх наших собственных жестов (пункт 5 списка правок).
    return InteractiveViewer(
      panEnabled: false,
      scaleEnabled: true,
      minScale: 1,
      maxScale: 6,
      onInteractionStart: (details) {
        if (details.pointerCount >= 2) onPinchStart();
      },
      child: Stack(
        fit: StackFit.expand,
        children: [
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapUp: addMode ? (details) => onCandidateAdded(details.localPosition / displayScale) : null,
            onPanUpdate: addMode
                ? null
                : (details) {
                    final local = details.localPosition;
                    final distA = (local - handleA).distance;
                    final distB = (local - handleB).distance;
                    if (distA <= _handleHitRadius && distA <= distB) {
                      final v = (local - displayCenter) / displayScale;
                      final newRx = v.distance.clamp(10, 5000).toDouble();
                      onCalibrationChanged(center, newRx, radiusY, math.atan2(v.dy, v.dx));
                    } else if (distB <= _handleHitRadius) {
                      final v = (local - displayCenter) / displayScale;
                      final projected = v.dx * perp.dx + v.dy * perp.dy;
                      final newRy = projected.abs().clamp(10, 5000).toDouble();
                      onCalibrationChanged(center, radiusX, newRy, angle);
                    } else {
                      onCalibrationChanged(center + details.delta / displayScale, radiusX, radiusY, angle);
                    }
                  },
            child: Stack(
              fit: StackFit.expand,
              children: [
                // Чёрно-белое — только для показа: контур калибровки и
                // найденные точки читаются на контрасте заметно лучше,
                // чем на цветном снимке (блики, оттенок бумаги), а сам
                // разбор и так всегда шёл по градациям серого.
                ColorFiltered(
                  colorFilter: const ColorFilter.matrix(<double>[
                    0.2126,
                    0.7152,
                    0.0722,
                    0,
                    0,
                    0.2126,
                    0.7152,
                    0.0722,
                    0,
                    0,
                    0.2126,
                    0.7152,
                    0.0722,
                    0,
                    0,
                    0,
                    0,
                    0,
                    1,
                    0,
                  ]),
                  child: Image.memory(bytes, fit: BoxFit.fill),
                ),
                CustomPaint(
                  painter:
                      _CalibrationPainter(center: displayCenter, radiusX: displayRx, radiusY: displayRy, angle: angle),
                ),
              ],
            ),
          ),
          for (var i = 0; i < candidates.length; i++)
            Builder(builder: (context) {
              final dotRadius = holeRadiusPx * displayScale;
              final hitRadius = math.max(dotRadius, _minTapRadius);
              return Positioned(
                left: candidates[i].dx * displayScale - hitRadius,
                top: candidates[i].dy * displayScale - hitRadius,
                width: hitRadius * 2,
                height: hitRadius * 2,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => onCandidateRemoved(i),
                  onPanUpdate: (details) => onCandidateMoved(
                    i,
                    candidates[i] + details.delta / displayScale,
                  ),
                  child: Center(
                    child: Container(
                      width: dotRadius * 2,
                      height: dotRadius * 2,
                      decoration: BoxDecoration(
                        color: Colors.redAccent.withValues(alpha: 0.85),
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white, width: 2),
                      ),
                    ),
                  ),
                ),
              );
            }),
        ],
      ),
    );
  }
}

class _CalibrationPainter extends CustomPainter {
  final Offset center;
  final double radiusX;
  final double radiusY;
  final double angle;

  const _CalibrationPainter({
    required this.center,
    required this.radiusX,
    required this.radiusY,
    required this.angle,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final ring = Paint()
      ..color = Colors.amberAccent
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3;

    canvas.save();
    canvas.translate(center.dx, center.dy);
    canvas.rotate(angle);
    canvas.drawOval(Rect.fromCenter(center: Offset.zero, width: radiusX * 2, height: radiusY * 2), ring);
    canvas.restore();

    final handle = Paint()..color = Colors.amberAccent;
    canvas.drawCircle(center, 6, handle);
    // Два независимых маркера — растянуть по каждой оси эллипса можно
    // отдельно (см. жесты в _ReviewOverlay), первый ещё и поворачивает.
    final handleA = center + Offset(radiusX * math.cos(angle), radiusX * math.sin(angle));
    final handleB = center + Offset(-radiusY * math.sin(angle), radiusY * math.cos(angle));
    canvas.drawCircle(handleA, 8, handle);
    canvas.drawCircle(handleB, 8, handle);
  }

  @override
  bool shouldRepaint(covariant _CalibrationPainter oldDelegate) =>
      oldDelegate.center != center ||
      oldDelegate.radiusX != radiusX ||
      oldDelegate.radiusY != radiusY ||
      oldDelegate.angle != angle;
}
