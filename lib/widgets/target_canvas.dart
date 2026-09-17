import 'dart:math' as math;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/target_color_scheme.dart';
import '../painters/target_painter.dart';
import '../state/personalization_view_model.dart';
import '../state/target_view_model.dart';

/// Подсказка при попытке записать выстрел на паузе.
///
/// Живёт здесь, а не в экране мишени, потому что тот и так импортирует
/// этот файл (кнопка "Добавить" под мишенью), а обратный импорт дал бы
/// циклическую зависимость между экраном и виджетом.
void showPauseAddHint(BuildContext context) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(
      const SnackBar(
        content: Text('Нажмите «Продолжить тренировку»'),
        duration: Duration(seconds: 2),
      ),
    );
}

/// Жестовый слой + отрисовка мишени (раздел 5 ТЗ, часть B.4
/// logic-personalization-spec.md, задача 3.3 dev-task-spec.md).
///
/// Остался ОДИН распознаватель — `ScaleGestureRecognizer`. Он же
/// обслуживает и щипок-зум, и перетаскивание пробоины при активной
/// правке, и пролистывание выстрелов двумя пальцами.
///
/// Ни удержания, ни тапа для добавления пробоины здесь больше нет
/// (решение пользователя): оба ставили пробоину сами по себе и
/// конфликтовали со всем подряд — с пинчем (распознаватель следит
/// только за первым пальцем), со свайпом страницы, с прокруткой.
/// Новый выстрел создаётся ИСКЛЮЧИТЕЛЬНО кнопкой под мишенью
/// (`_ShotActionBar` в target_screen.dart).
class TargetCanvas extends StatefulWidget {
  const TargetCanvas({super.key});

  @override
  State<TargetCanvas> createState() => _TargetCanvasState();
}

class _TargetCanvasState extends State<TargetCanvas> {
  static const double _pixelsPerShot = 40.0; // B.4

  /// Порог решения "это щипок" — накопленное с начала жеста отклонение
  /// `ScaleGestureRecognizer.scale` от 1.0 (доля, не пиксели).
  static const double _zoomScaleDeltaThreshold = 0.04;

  /// Порог решения "это пролистывание" — накопленное с начала жеста
  /// смещение середины между пальцами, px.
  static const double _scrollFocalDriftThresholdPx = 16.0;

  /// Сколько пальцев сейчас на экране. Считается сырыми событиями, до
  /// арены жестов: от этого зависит, можно ли листать страницы —
  /// двухпальцевый жест на мишени принадлежит мишени, а не рабочему
  /// столу.
  int _activePointers = 0;

  /// Ближе этого к центру считаем, что смещения нет вовсе.
  static const double _centreEpsilonMm = 0.05;

  /// Сообщает вью-модели, лежат ли на мишени два пальца.
  ///
  /// Нужно это не мишени, а рабочему столу: пока пальцев два, PageView
  /// не должен листать страницы. Иначе щипок для зума норовит уехать на
  /// соседнюю страницу — при сведении пальцы всегда смещаются вбок, и
  /// горизонтальную составляющую PageView считает своей.
  void _syncMultiTouch(TargetViewModel vm) {
    vm.setMultiTouch(_activePointers >= 2);
  }

  /// Текущий жест начат на кольце компаса — значит меняем только угол,
  /// не трогая результат. Решается ОДИН раз в начале жеста: иначе
  /// пробоина прыгала бы между режимами, когда палец пересекает границу
  /// зоны компаса по дороге.
  bool _gestureOnCompass = false;

  // Сколько пальцев было в жесте — нужно только чтобы поймать появление
  // второго пальца ПОСЛЕ начала жеста (см. _onScaleUpdate) и отменить
  // правку: одиночным касанием пробоина больше не ставится нигде, это
  // делает исключительно кнопка под мишенью.
  int _maxPointerCount = 0;

  // Мультитач-арбитраж (B.4): режим (щипок или пролистывание) решается
  // один раз за жест по НАКОПЛЕННЫМ с начала жеста величинам, а
  // дальнейшее применение зума — по межкадровой разнице (см.
  // _onScaleUpdate).
  double? _lastScaleDistance;
  Offset? _lastFocalPoint;
  Offset? _gestureStartFocal;
  double _accumulatedFocalDy = 0;
  bool _twoFingerModeDecided = false;
  bool _isZoomGesture = false;

  Size _canvasSize = Size.zero;

  @override
  Widget build(BuildContext context) {
    final vm = context.watch<TargetViewModel>();
    final personalization = context.watch<PersonalizationViewModel>();
    final colors = personalization.scheme;

    return LayoutBuilder(
      builder: (context, constraints) {
        _canvasSize = Size(constraints.maxWidth, constraints.maxHeight);
        // Listener считает пальцы «сырыми» событиями, до арены жестов.
        // Ни один распознаватель этого не даёт: удержание видит только
        // свой первый палец и потому не отличает долгое нажатие от
        // медленного пинча.
        return Listener(
          onPointerDown: (_) {
            _activePointers++;
            _syncMultiTouch(vm);
          },
          onPointerUp: (_) {
            _activePointers = math.max(0, _activePointers - 1);
            _syncMultiTouch(vm);
          },
          onPointerCancel: (_) {
            _activePointers = math.max(0, _activePointers - 1);
            _syncMultiTouch(vm);
          },
          child: RawGestureDetector(
          gestures: <Type, GestureRecognizerFactory>{
            // Ни удержания, ни тапа здесь больше нет — оба когда-то
            // ставили пробоину и конфликтовали со всем подряд: с пинчем
            // (распознаватель следит только за первым пальцем), со
            // свайпом страницы, с прокруткой выстрелов. Новый выстрел
            // создаётся ИСКЛЮЧИТЕЛЬНО кнопкой под мишенью (решение
            // пользователя) — сама мишень теперь отвечает только за
            // зум, перетаскивание черновика при активной правке и
            // пролистывание выстрелов двумя пальцами.
            ScaleGestureRecognizer: GestureRecognizerFactoryWithHandlers<ScaleGestureRecognizer>(
              () => ScaleGestureRecognizer(),
              (ScaleGestureRecognizer instance) {
                instance.onStart = (details) => _onScaleStart(details, vm);
                instance.onUpdate = (details) => _onScaleUpdate(details, vm);
                instance.onEnd = (details) => _onScaleEnd();
              },
            ),
          },
          child: Stack(
            fit: StackFit.expand,
            children: [
              CustomPaint(
                painter: TargetPainter(
                  face: vm.face,
                  colors: colors,
                  visibleShots: vm.visibleShots,
                  selectedShot: vm.selectedShot,
                  currentSeriesNo: vm.session.shots.isEmpty ? 1 : vm.session.shots.last.seriesNo,
                  isEditing: vm.isEditing,
                  draftXMm: vm.isEditing ? vm.draftXMm : null,
                  draftYMm: vm.isEditing ? vm.draftYMm : null,
                  draftShotNumber: vm.draftShotNumber,
                  zoom: vm.zoom,
                  pan: Offset(vm.panX, vm.panY),
                ),
              ),
              ..._buildCornerValues(vm, colors),
            ],
          ),
          ),
        );
      },
    );
  }

  // ---- Преобразование координат ----

  Offset _screenToMm(TargetViewModel vm, Offset screenPos) {
    final center = _targetCenter(vm);
    final radiusPx = _targetRadiusPx(vm);
    final mmToPx = radiusPx / vm.face.faceRadiusMm;
    final rel = screenPos - center;
    return Offset(rel.dx / mmToPx, -rel.dy / mmToPx);
  }

  Offset _targetCenter(TargetViewModel vm) =>
      Offset(_canvasSize.width / 2, _canvasSize.height / 2) + Offset(vm.panX, vm.panY);

  double _targetRadiusPx(TargetViewModel vm) =>
      math.min(_canvasSize.width, _canvasSize.height) / 2 * vm.zoom;

  /// Квадрат бумаги мишени на экране — тот же прямоугольник, что рисует
  /// `TargetPainter`. По его углам раскладываются значения выстрела.
  Rect _blankRect(TargetViewModel vm) {
    final r = _targetRadiusPx(vm);
    return Rect.fromCenter(center: _targetCenter(vm), width: r * 2, height: r * 2);
  }

  /// Попало ли касание в кольцо компаса.
  ///
  /// Центр берётся С УЧЁТОМ панорамирования — в прежней версии радиус
  /// касания считался от геометрического центра холста без `pan`, и
  /// после сдвига мишени зона компаса уезжала от нарисованного кольца.
  bool _isInCompassZone(Offset localPos, TargetViewModel vm) {
    final radiusPx = _targetRadiusPx(vm);
    if (radiusPx <= 0) return false;
    final d = (localPos - _targetCenter(vm)).distance;
    return d >= TargetPainter.compassZoneFraction * radiusPx && d <= radiusPx * 1.2;
  }

  /// Единая точка применения перетаскивания во время правки: по кольцу
  /// компаса — только угол, иначе — свободно по XY.
  void _applyEditDrag(Offset localPos, TargetViewModel vm) {
    final mmPos = _screenToMm(vm, localPos);
    if (_gestureOnCompass) {
      vm.setDraftAngleFromPoint(mmPos.dx, mmPos.dy);
    } else {
      vm.updateDraftPosition(mmPos.dx, mmPos.dy);
    }
  }

  // ---- Scale (пинч-зум / пролистывание выстрелов, B.4) ----

  void _onScaleStart(ScaleStartDetails details, TargetViewModel vm) {
    _lastScaleDistance = null;
    _lastFocalPoint = details.focalPoint;
    _gestureStartFocal = details.focalPoint;
    _accumulatedFocalDy = 0;
    _twoFingerModeDecided = false;
    _maxPointerCount = details.pointerCount;

    if (details.pointerCount >= 2) {
      vm.onTwoFingerGestureStarted(); // немедленно отменяет активную правку
      return;
    }
    // Один палец/курсор, идёт правка — сразу подхватываем пробоину под
    // точку касания, не дожидаясь порога сдвига для onUpdate. Режим
    // (компас или свободное XY) решается здесь и на весь жест.
    if (vm.isEditing) {
      _gestureOnCompass = _isInCompassZone(details.localFocalPoint, vm);
      _applyEditDrag(details.localFocalPoint, vm);
    }
  }

  void _onScaleUpdate(ScaleUpdateDetails details, TargetViewModel vm) {
    if (details.pointerCount >= 2 && _maxPointerCount < 2) {
      // Второй палец мог появиться уже после начала жеста — тогда
      // _onScaleStart о нём не знал. Отменяем правку здесь.
      vm.onTwoFingerGestureStarted();
    }
    if (details.pointerCount > _maxPointerCount) _maxPointerCount = details.pointerCount;

    if (details.pointerCount < 2) {
      // Один палец/курсор во время активной правки — прямое
      // перетаскивание пробоины под палец/курсор (а не только степперы
      // +/-, по просьбе пользователя после первого прогона на реальном
      // устройстве). Работает и для новой, и для перемещаемой пробоины
      // (isAddingNew — без разницы, обе двигаются через draftX/Y).
      if (vm.isEditing) {
        _applyEditDrag(details.localFocalPoint, vm);
      }
      return;
    }
    final lastFocal = _lastFocalPoint ?? details.focalPoint;
    final deltaFocal = details.focalPoint - lastFocal;
    _lastFocalPoint = details.focalPoint;

    // Применение зума — по МЕЖКАДРОВОЙ разнице: scale от Flutter
    // кумулятивен с начала жеста, а нужен прирост с прошлого кадра.
    final currentDistance = details.scale;
    final prevDistance = _lastScaleDistance ?? currentDistance;
    final frameScaleDelta = currentDistance == 0 ? 1.0 : currentDistance / (prevDistance == 0 ? 1 : prevDistance);
    _lastScaleDistance = currentDistance;

    // Решение режима — по НАКОПЛЕННЫМ с начала жеста величинам, а не по
    // межкадровым: межкадровое смещение середины между пальцами почти
    // всегда больше пары пикселей уже от дрожания руки, и решение
    // "это пролистывание" срабатывало раньше, чем масштаб успевал
    // измениться заметно — щипок почти всегда распознавался как свайп
    // выстрелов, а не как зум (отсюда и "зум не реагирует", и особенно
    // "зажат на максимуме, обратно не крутится": сжать пальцы обратно
    // ровно по той же линии почти невозможно, и любое дрожание тут же
    // уводило жест в пролистывание).
    if (!_twoFingerModeDecided) {
      final cumulativeScaleDelta = (details.scale - 1.0).abs();
      final cumulativeFocalDrift = (details.focalPoint - (_gestureStartFocal ?? details.focalPoint)).distance;
      if (cumulativeScaleDelta > _zoomScaleDeltaThreshold) {
        _isZoomGesture = true;
        _twoFingerModeDecided = true;
      } else if (cumulativeFocalDrift > _scrollFocalDriftThresholdPx) {
        _isZoomGesture = false;
        _twoFingerModeDecided = true;
      }
    }

    if (_twoFingerModeDecided && _isZoomGesture) {
      vm.applyScale(frameScaleDelta, deltaFocal.dx, deltaFocal.dy);
    } else if (_twoFingerModeDecided && !_isZoomGesture) {
      _accumulatedFocalDy += deltaFocal.dy;
      final shotDelta = _accumulatedFocalDy / _pixelsPerShot;
      if (shotDelta.abs() >= 1) {
        vm.scrollByShots(-shotDelta); // свайп вниз пальцами -> назад по выстрелам
        _accumulatedFocalDy -= shotDelta.truncate() * _pixelsPerShot;
      }
    }
  }

  // ---- Завершение жеста ----

  void _onScaleEnd() {
    _lastScaleDistance = null;
    _lastFocalPoint = null;
    _gestureStartFocal = null;
    _twoFingerModeDecided = false;
    _accumulatedFocalDy = 0;
    _maxPointerCount = 0;
  }

  /// Значения выстрела ПО УГЛАМ БУМАГИ МИШЕНИ — вместо прежней нижней
  /// панели (решение пользователя).
  ///
  /// Кладутся именно на углы бланка, а не в углы холста: бланк
  /// квадратный, а окно обычно шире, и в углах холста подписи висели бы
  /// на пустом фоне вне мишени.
  ///
  /// Словесных подписей нет — их убрали по просьбе пользователя. Каждое
  /// значение опознаётся по собственному обозначению: координаты
  /// заканчиваются на «мм», сумма начинается со знака Σ, направление
  /// показано стрелкой. Счётчик выстрелов не выводится: номер написан
  /// прямо на пробоине.
  ///
  /// Во время правки показываются значения ЧЕРНОВИКА — так видно, что
  /// именно меняет компас и колесо десятых.
  List<Widget> _buildCornerValues(TargetViewModel vm, TargetColorScheme colors) {
    final editing = vm.isEditing;
    final shot = vm.selectedShot;
    if (!editing && shot == null) return const [];

    final score = editing ? vm.draftScore : shot?.score;
    final angleDeg = editing ? vm.draftAngleDeg : shot?.angleDeg;
    final x = editing ? vm.draftXMm : shot!.xMm;
    final y = editing ? vm.draftYMm : shot!.yMm;
    final radiusMm = math.sqrt(x * x + y * y);

    final rect = _blankRect(vm);
    const pad = 10.0;
    // Углы бланка могут уехать за пределы холста при зуме — прижимаем
    // подписи к видимой области, иначе они просто пропадут.
    final left = rect.left.clamp(0.0, math.max(0.0, _canvasSize.width - 130)) + pad;
    final right = (_canvasSize.width - rect.right).clamp(0.0, math.max(0.0, _canvasSize.width - 130)) + pad;
    final top = rect.top.clamp(0.0, math.max(0.0, _canvasSize.height - 70)) + pad;
    final bottom = (_canvasSize.height - rect.bottom).clamp(0.0, math.max(0.0, _canvasSize.height - 70)) + pad;

    // Цвет подписи выбирается по тому, НА ЧЁМ она оказалась.
    //
    // При сильном зуме чёрное яблоко разрастается на весь экран, и углы
    // бланка вместе с подписями уезжают на него: тёмный текст на тёмном
    // фоне пропадал. Считаем, где стоит каждый угол, и берём цвет для
    // яблока или для бумаги.
    Color colorAt(double dx, double dy) {
      final mm = _screenToMm(vm, Offset(dx, dy));
      final onBullseye = mm.distance <= vm.face.bullseyeRadiusMm;
      return onBullseye ? colors.ringLabelsOnBullseye : colors.ringLabelsOnPaper;
    }

    final topLeft = colorAt(left, top);
    final topRight = colorAt(_canvasSize.width - right, top);
    final bottomLeft = colorAt(left, _canvasSize.height - bottom);
    final bottomRight = colorAt(_canvasSize.width - right, _canvasSize.height - bottom);

    return [
      // Результат — крупно, без подписи.
      Positioned(
        left: left,
        top: top,
        child: _CornerText(
          text: score == null ? '—' : score.toStringAsFixed(1),
          color: topLeft,
          big: true,
        ),
      ),
      // Сумма — знак Σ прямо перед числом.
      Positioned(
        right: right,
        top: top,
        child: _CornerText(text: 'Σ ${_sumFor(vm)}', color: topRight),
      ),
      // Координаты — единицы измерения в конце строки.
      Positioned(
        left: left,
        bottom: bottom,
        child: _CornerText(
          text: 'X ${x.toStringAsFixed(1)}   Y ${y.toStringAsFixed(1)} мм',
          color: bottomLeft,
        ),
      ),
      // Направление — стрелка плюс часы с минутами, без слов.
      Positioned(
        right: right,
        bottom: bottom,
        child: _DirectionValue(
          angleDeg: angleDeg,
          // «Центр» — это X=0, Y=0, и ничто другое.
          //
          // Раньше порогом стоял радиус пробоины (2.25 мм на десятке),
          // и выстрел с координатами −1.5 / −0.2 подписывался как
          // «центр», хотя до центра полтора миллиметра и стрелка нужна.
          meaningful: radiusMm >= _centreEpsilonMm,
          color: bottomRight,
        ),
      ),
    ];
  }

  String _sumFor(TargetViewModel vm) {
    final idx = vm.selectedIndex;
    if (idx < 0) return '0.0';
    final shots = vm.session.shots.sublist(0, idx + 1);
    if (vm.displayMode == DisplayMode.series) {
      final seriesNo = shots.last.seriesNo;
      final sum = shots.where((s) => s.seriesNo == seriesNo).fold(0.0, (a, s) => a + s.score);
      return sum.toStringAsFixed(1);
    }
    final sum = shots.fold(0.0, (a, s) => a + s.score);
    return sum.toStringAsFixed(1);
  }
}

/// Значение в углу бланка. Без словесной подписи — смысл несёт само
/// обозначение внутри строки (мм, Σ).
class _CornerText extends StatelessWidget {
  final String text;
  final Color color;
  final bool big;

  const _CornerText({required this.text, required this.color, this.big = false});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Text(
      text,
      style: (big ? theme.textTheme.headlineSmall : theme.textTheme.titleMedium)
          ?.copyWith(color: color),
    );
  }
}

/// Направление выстрела: стрелка + часы с минутами, без слов.
///
/// Стрелка защёлкивается по восьми румбам (вверх, вправо-вверх, вправо…
/// — шаг 45°), как просил пользователь. Часы при этом показываются
/// точные, с минутами: полный круг — 12 часов, значит один градус это
/// две минуты циферблата. Минуты не подписываются — формат «3:25» и так
/// читается как положение на циферблате.
class _DirectionValue extends StatelessWidget {
  final double? angleDeg;
  final bool meaningful;
  final Color color;

  const _DirectionValue({
    required this.angleDeg,
    required this.meaningful,
    required this.color,
  });

  /// Часы и минуты циферблата из угла: 360° = 12 ч = 720 минут.
  static (int, int) clockHm(double deg) {
    final total = (deg * 2).round() % 720; // минут от 12 часов
    final hours = total ~/ 60;
    return (hours == 0 ? 12 : hours, total % 60);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final deg = angleDeg;
    if (deg == null || !meaningful) {
      // Раньше здесь стоял просто прочерк, и было непонятно, что
      // вообще не показано. Теперь угол честно подписан: пробоина
      // накрыла центр, направления у неё нет — показывать стрелку
      // значило бы выдавать шум округления координат за снос.
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.adjust, size: 20, color: color),
          const SizedBox(width: 6),
          Text(
            'центр',
            style: theme.textTheme.titleMedium?.copyWith(color: color),
          ),
        ],
      );
    }

    final (h, m) = clockHm(deg);
    // Восемь румбов: округляем к ближайшему кратному 45°.
    final snapped = (deg / 45).round() * 45.0;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Transform.rotate(
          // Icons.arrow_upward смотрит вверх, а угол отсчитывается от
          // 12 часов по часовой стрелке — как раз поворот по часовой,
          // положительный в системе координат Flutter.
          angle: snapped * math.pi / 180,
          child: Icon(Icons.arrow_upward, size: 22, color: color),
        ),
        const SizedBox(width: 6),
        Text(
          '$h:${m.toString().padLeft(2, '0')}',
          style: theme.textTheme.titleMedium?.copyWith(color: color),
        ),
      ],
    );
  }
}
