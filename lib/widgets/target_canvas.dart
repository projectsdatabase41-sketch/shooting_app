import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../logic/scoring.dart';
import '../models/shot.dart';
import 'package:provider/provider.dart';
import '../models/target_color_scheme.dart';
import '../painters/target_painter.dart';
import '../state/personalization_view_model.dart';
import '../state/target_view_model.dart';
import '../i18n/i18n.dart';

/// Подсказка при попытке записать выстрел на паузе.
///
/// Живёт здесь, а не в экране мишени, потому что тот и так импортирует
/// этот файл (кнопка "Добавить" под мишенью), а обратный импорт дал бы
/// циклическую зависимость между экраном и виджетом.
void showPauseAddHint(BuildContext context) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(tr('Нажмите «Продолжить тренировку»')),
        duration: const Duration(seconds: 2),
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
/// Индекс выстрела, ближайшего к точке (мм); -1 — выстрелов нет.
int nearestShotIndex(List<Shot> shots, double xMm, double yMm) {
  var best = -1;
  var bestD = double.infinity;
  for (var i = 0; i < shots.length; i++) {
    final dx = shots[i].xMm - xMm, dy = shots[i].yMm - yMm;
    final d = dx * dx + dy * dy;
    if (d < bestD) {
      bestD = d;
      best = i;
    }
  }
  return best;
}

class TargetCanvas extends StatefulWidget {
  /// Просмотр законченной тренировки: касание выбирает ближайший к нему
  /// выстрел. На рабочем столе выключено — там касание ничего не делает.
  final bool tapToSelect;

  /// Рабочий стол тренировки: касание мишени ставит выстрел (лупа над пальцем, отпустил — записан),
  /// как в финале. Два пальца — зум, выстрел при этом не ставится.
  final bool addByTouch;
  const TargetCanvas({super.key, this.tapToSelect = false, this.addByTouch = false});

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

  /// Где палец при перетаскивании пробоины (для лупы); `null` — палец не на мишени.
  Offset? _finger;

  /// Идёт выстрел касанием (см. [TargetCanvas.addByTouch]).
  bool _autoAdd = false;

  /// Касание ещё не решено: короткий тап ставит выстрел, удержание начинает его с лупой, а быстрое
  /// движение пальца — это прокрутка страницы (выстрел не ставится).
  bool _pendingAdd = false;
  Offset _downPos = Offset.zero;
  Offset _lastPos = Offset.zero;
  Timer? _holdTimer;
  static const _holdDelay = Duration(milliseconds: 140);
  static const _moveSlopPx = 10.0;

  void _beginAddAt(TargetViewModel vm, Offset pos) {
    vm.beginAddNew();
    _autoAdd = vm.isEditing;
    if (_autoAdd) {
      _applyEditDrag(pos, vm);
      _trackFinger(pos);
    }
  }

  void _cancelPending() {
    _holdTimer?.cancel();
    _pendingAdd = false;
    // Касание оказалось прокруткой страницы — предпросмотр лупы убираем.
    if (mounted && _finger != null && !_autoAdd) setState(() => _finger = null);
  }

  @override
  void dispose() {
    _holdTimer?.cancel();
    // Лупа живёт в корневом Overlay — снимаем её вручную (как в финале).
    _loupeEntry?.remove();
    _loupeEntry = null;
    super.dispose();
  }

  /// Лупа — точно как в финале (ShotPad в final_run_screen.dart; отзыв
  /// владельца 23.11 «сделай лупу прямо как в финале»): диаметр 190,
  /// увеличение формулой финала (шаг десятой доли ≈ 4,5 px, мягче прежнего —
  /// сильное увеличение «убегало» из-под пальца), и лупа ВСЕГДА стоит над
  /// пальцем в верхнем слое экрана (Overlay), у верхнего края просто
  /// упираясь в него. Логика постановки/перетаскивания выстрела не менялась —
  /// только вид и позиционирование лупы.
  static const double _loupePxPerStep = 4.5;
  static const double _loupeSize = 190;

  /// От пальца до центра лупы — как в финале (ShotPad._gap).
  static const double _loupeGap = 125;

  OverlayEntry? _loupeEntry;

  double _loupeZoom(TargetViewModel vm) {
    final st = vm.face.decimalStepMm;
    final stepMm = st > 0 ? st : 1.0;
    return (_loupePxPerStep * vm.face.faceRadiusMm / (stepMm * _loupeSize / 2))
        .clamp(3.0, 24.0)
        .toDouble();
  }

  /// Запоминает, где палец: лупа теперь стоит над пальцем и позиционируется
  /// заново у каждой его позиции (поведение финала), без накопленного сдвига.
  void _trackFinger(Offset pos) {
    if (_finger == pos) return;
    setState(() => _finger = pos);
  }

  /// Показывает/прячет лупу в верхнем слое экрана — как в финале
  /// (ShotPad._syncOverlay): слой Overlay поверх всех окон, иначе ClipRect
  /// вокруг холста обрезал бы лупу у краёв.
  void _syncLoupeOverlay() {
    if (!mounted) return;
    var show = false;
    if (_finger != null) {
      final vm = context.read<TargetViewModel>();
      show = vm.isEditing || _pendingAdd;
    }
    if (show && _loupeEntry == null) {
      _loupeEntry = OverlayEntry(builder: (ctx) {
        final box = context.findRenderObject();
        if (box is! RenderBox || !box.attached) return const SizedBox.shrink();
        final mq = MediaQuery.of(ctx);
        final vm = context.read<TargetViewModel>();
        final colors = context.read<PersonalizationViewModel>().scheme;
        return Positioned.fill(
          child: IgnorePointer(
            child: Stack(clipBehavior: Clip.none, children: [
              if (_finger != null)
                _buildLoupe(vm, colors, _finger!, _canvasSize,
                    origin: box.localToGlobal(Offset.zero),
                    screen: mq.size,
                    safeTop: mq.padding.top),
            ]),
          ),
        );
      });
      Overlay.of(context, rootOverlay: true).insert(_loupeEntry!);
    } else if (!show && _loupeEntry != null) {
      _loupeEntry!.remove();
      _loupeEntry = null;
    } else if (show) {
      _loupeEntry!.markNeedsBuild();
    }
  }

  /// Лупа над пальцем в координатах всего экрана — дословный перенос
  /// ShotPad._buildLoupe из финала (отзыв 23.11 №1), отличия только в
  /// источнике данных: правится черновик пробоины, а не откладывается выстрел.
  Widget _buildLoupe(TargetViewModel vm, TargetColorScheme colors, Offset f, Size size,
      {required Offset origin, required Size screen, required double safeTop}) {
    // До начала правки (касание ещё не превратилось в черновой выстрел) лупа
    // показывает окрестность точки под пальцем — чтобы тап был не вслепую.
    final mm = vm.isEditing ? Offset(vm.draftXMm, vm.draftYMm) : _screenToMm(vm, f);
    final score = vm.isEditing
        ? formatScore(vm.draftScore ?? 0.0, vm.face)
        : formatScore(scoreForPoint(mm.dx, mm.dy, vm.face), vm.face);
    // Лупа ВСЕГДА над пальцем и поверх всех окон, не прыгает вниз: у самого
    // верха экрана просто упирается в его край (как ShotPad). Нижняя граница —
    // верх холста: он и так ниже статус-бара и верхней панели тренировки
    // (аналог safeTop финала), и лупа не должна прятаться под панелью.
    final g = origin + f;
    final cx = g.dx.clamp(_loupeSize / 2, screen.width - _loupeSize / 2);
    final cy = math.max(g.dy - _loupeGap, math.max(safeTop, origin.dy) + _loupeSize / 2);
    final kz = _loupeSize / 2 * _loupeZoom(vm) / vm.face.faceRadiusMm;
    // Точка выстрела — в центре лупы. Знак по Y: в мм ось вверх, на экране
    // вниз, поэтому pan.dy = +mm.dy.
    final pan = Offset(-mm.dx * kz, mm.dy * kz);
    return Positioned(
      left: cx - _loupeSize / 2,
      top: cy - _loupeSize / 2,
      width: _loupeSize,
      height: _loupeSize,
      child: IgnorePointer(
        child: Stack(clipBehavior: Clip.none, children: [
          DecoratedBox(
            // Тень лупы — объём вместо плоской наклейки.
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                    color: Colors.black.withValues(alpha: 0.45),
                    blurRadius: 22,
                    spreadRadius: 1,
                    offset: const Offset(0, 10)),
              ],
            ),
            child: DecoratedBox(
              // Рамка рисуется ПОВЕРХ (foreground): иначе она сужает область
              // и центр мишени смещается на её толщину относительно перекрестия.
              position: DecorationPosition.foreground,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white.withValues(alpha: 0.9), width: 4),
              ),
              child: ClipOval(
                child: Stack(children: [
                  Positioned.fill(
                    child: CustomPaint(
                      painter: TargetPainter(
                        face: vm.face,
                        colors: colors,
                        visibleShots: vm.visibleShots,
                        selectedShot: vm.selectedShot,
                        currentSeriesNo:
                            vm.session.shots.isEmpty ? 1 : vm.session.shots.last.seriesNo,
                        isEditing: vm.isEditing,
                        draftXMm: vm.isEditing ? vm.draftXMm : null,
                        draftYMm: vm.isEditing ? vm.draftYMm : null,
                        draftShotNumber: vm.isEditing ? vm.draftShotNumber : null,
                        zoom: _loupeZoom(vm),
                        pan: pan,
                      ),
                    ),
                  ),
                  // Перекрестие в центре — как в финале: кольцо ровно по
                  // размеру пробоины (в масштабе лупы) и точка.
                  Positioned.fill(
                    child: CustomPaint(painter: _LoupeCentrePainter(holeR: 2.25 * kz)),
                  ),
                  // Блик и виньетка стекла.
                  Positioned.fill(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: RadialGradient(
                          center: const Alignment(-0.45, -0.55),
                          radius: 1.0,
                          colors: [
                            Colors.white.withValues(alpha: 0.28),
                            Colors.white.withValues(alpha: 0.0),
                            Colors.black.withValues(alpha: 0.18),
                          ],
                          stops: const [0.0, 0.55, 1.0],
                        ),
                      ),
                    ),
                  ),
                ]),
              ),
            ),
          ),
          // Значение выстрела над лупой — как в финале.
          Positioned(
            left: 0,
            right: 0,
            top: -30,
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
                decoration: BoxDecoration(
                    color: Colors.black87, borderRadius: BorderRadius.circular(12)),
                child: Text(score,
                    style: const TextStyle(
                        color: Colors.white, fontSize: 20, fontWeight: FontWeight.w800)),
              ),
            ),
          ),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final vm = context.watch<TargetViewModel>();
    final personalization = context.watch<PersonalizationViewModel>();
    final colors = personalization.scheme;

    return LayoutBuilder(
      builder: (context, constraints) {
        _canvasSize = Size(constraints.maxWidth, constraints.maxHeight);
        // Лупа живёт в Overlay и синхронизируется после кадра, как в финале
        // (ShotPad._syncOverlay, отзыв 23.11 №1).
        WidgetsBinding.instance.addPostFrameCallback((_) => _syncLoupeOverlay());
        // Listener считает пальцы «сырыми» событиями, до арены жестов.
        // Ни один распознаватель этого не даёт: удержание видит только
        // свой первый палец и потому не отличает долгое нажатие от
        // медленного пинча.
        return Listener(
          onPointerDown: (e) {
            _activePointers++;
            _syncMultiTouch(vm);
            if (!widget.addByTouch) return;
            if (_activePointers == 1 && !vm.isEditing && vm.canEditShots && !vm.face.hitMiss) {
              if (!vm.canAddShotNow) {
                showPauseAddHint(context);
                return;
              }
              // Решаем по тому, что сделает палец: тап — выстрел, удержание — выстрел с лупой,
              // быстрый сдвиг — прокрутка страницы.
              _pendingAdd = true;
              _downPos = _lastPos = e.localPosition;
              // Лупа показывается сразу при касании, ещё до решения «тап или
              // прокрутка»: иначе при быстром тапе пробоина ставилась вслепую
              // (отзыв 13.11 «стоит добавить лупу, чтобы видеть, куда проставляю
              // выстрел») — раньше она появлялась только после удержания.
              _trackFinger(e.localPosition);
              _holdTimer?.cancel();
              _holdTimer = Timer(_holdDelay, () {
                if (!mounted || !_pendingAdd) return;
                _pendingAdd = false;
                _beginAddAt(vm, _lastPos);
              });
            } else if (_activePointers >= 2) {
              // Второй палец — это зум: выстрел не ставим.
              _cancelPending();
              if (_autoAdd) {
                _autoAdd = false;
                vm.onTwoFingerGestureStarted();
                setState(() => _finger = null);
              }
            }
          },
          onPointerMove: (e) {
            _lastPos = e.localPosition;
            // Палец пошёл — это не прокрутка, а черновая правка: ведём точку
            // за пальцем. Раньше движение отменяло касание, страница
            // прокручивалась, и лупа исчезала — сдвинуть её было нельзя
            // (отзыв 16.11).
            if (_pendingAdd && (e.localPosition - _downPos).distance > _moveSlopPx) {
              _holdTimer?.cancel();
              _pendingAdd = false;
              _beginAddAt(vm, e.localPosition);
            }
            if (_autoAdd && _activePointers == 1) {
              _applyEditDrag(e.localPosition, vm);
              _trackFinger(e.localPosition);
            }
          },
          onPointerUp: (e) {
            if (_pendingAdd && _activePointers == 1) {
              // Короткий тап: выстрел ставится сразу в точку касания.
              _cancelPending();
              _beginAddAt(vm, _downPos);
              if (_autoAdd) {
                _autoAdd = false;
                if (vm.isEditing && vm.isAddingNew) vm.confirmEdit();
                setState(() => _finger = null);
              }
            } else if (_autoAdd && _activePointers == 1) {
              _autoAdd = false;
              if (vm.isEditing && vm.isAddingNew) vm.confirmEdit();
              setState(() => _finger = null);
            }
            _activePointers = math.max(0, _activePointers - 1);
            _syncMultiTouch(vm);
          },
          onPointerCancel: (_) {
            _cancelPending();
            if (_autoAdd) {
              _autoAdd = false;
              vm.cancelEditing();
              setState(() => _finger = null);
            }
            _activePointers = math.max(0, _activePointers - 1);
            _syncMultiTouch(vm);
          },
          child: RawGestureDetector(
          gestures: <Type, GestureRecognizerFactory>{
            if (widget.tapToSelect)
              TapGestureRecognizer: GestureRecognizerFactoryWithHandlers<TapGestureRecognizer>(
                () => TapGestureRecognizer(),
                (TapGestureRecognizer instance) {
                  instance.onTapUp = (details) {
                    if (vm.isEditing) return;
                    final mm = _screenToMm(vm, details.localPosition);
                    final i = nearestShotIndex(vm.session.shots, mm.dx, mm.dy);
                    if (i >= 0) vm.selectIndex(i);
                  };
                },
              ),
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
                  sighting: vm.isSightingSeries,
                ),
              ),
              ..._buildCornerValues(vm, colors),
              // Плашка «Пристрелка» отсюда убрана: уголок теперь рисует сам
              // TargetPainter (SightingCorner) ровно по углу бланка, а плашка
              // в том же правом верхнем углу его наполовину закрывала
              // (отзыв владельца 22.11: «уголок пристрелки вообще не верный»).
              // Подпись серии и так выводится в шапке серии на экране мишени.
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

  /// Применяет перетаскивание при правке: всегда свободное перемещение XY.
  /// Компас убран (отзыв 17.11 08:04) — больше нет режима "только угол".
  void _applyEditDrag(Offset localPos, TargetViewModel vm) {
    final mmPos = _screenToMm(vm, localPos);
    vm.updateDraftPosition(mmPos.dx, mmPos.dy);
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
      if (_finger != null) setState(() => _finger = null);
      return;
    }
    // Один палец/курсор, идёт правка — сразу подхватываем пробоину под
    // точку касания, не дожидаясь порога сдвига для onUpdate. Режим
    // (компас или свободное XY) решается здесь и на весь жест.
    if (vm.isEditing && !_autoAdd) {
      _applyEditDrag(details.localFocalPoint, vm);
      _trackFinger(details.localFocalPoint);
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
      if (vm.isEditing && !_autoAdd) {
        _applyEditDrag(details.localFocalPoint, vm);
        _trackFinger(details.localFocalPoint);
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
    if (_finger != null && !_autoAdd) setState(() => _finger = null);
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
          text: score == null ? '—' : formatScore(score, vm.face),
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
          text: tr('X {p}   Y {p2} мм', {'p': x.toStringAsFixed(1), 'p2': y.toStringAsFixed(1)}),
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
      return formatScore(sum, vm.face);
    }
    final sum = shots.fold(0.0, (a, s) => a + s.score);
    return formatScore(sum, vm.face);
  }
}

/// Перекрестие лупы в центре — копия режима `lens` из ShotMarkerPainter
/// финала (отзыв 23.11 №1 «сделай лупу прямо как в финале»): кольцо ровно
/// по размеру пробоины (в масштабе лупы) и точка в центре (10% диаметра
/// пробоины) — для точного прицеливания.
class _LoupeCentrePainter extends CustomPainter {
  final double holeR;
  const _LoupeCentrePainter({required this.holeR});

  @override
  void paint(Canvas canvas, Size size) {
    final f = Offset(size.width / 2, size.height / 2);
    final rr = math.max(3.0, holeR);
    final dotR = math.max(1.2, rr * 0.1);
    final white = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6;
    final dark = Paint()
      ..color = Colors.black.withValues(alpha: 0.7)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.2;
    for (final p in [dark, white]) {
      canvas.drawCircle(f, rr, p);
    }
    canvas.drawCircle(f, dotR + 0.9, Paint()..color = Colors.black.withValues(alpha: 0.7));
    canvas.drawCircle(f, dotR, Paint()..color = Colors.white);
  }

  @override
  bool shouldRepaint(_LoupeCentrePainter old) => old.holeR != holeR;
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
            tr('центр'),
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
