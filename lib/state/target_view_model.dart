import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';
import '../logic/scoring.dart';
import '../logic/session_logic.dart';
import '../models/exercise.dart';
import '../models/series_spec.dart';
import '../models/shot.dart';
import '../models/target_face.dart';
import '../models/training_session.dart';
import 'app_data_store.dart';

enum DisplayMode { single, series, all }

/// Состояние одной тренировки/мишени (раздел 2 tech-spec-v2.md:
/// `TargetViewModel` на `ChangeNotifier`). Единственная точка правды для
/// `canEdit` (часть C.2 логики-спека) — все контролы правки проверяют
/// именно этот флаг, элементы скрываются, не дизейблятся.
class TargetViewModel extends ChangeNotifier {
  final AppDataStore store;
  static const _uuid = Uuid();

  TrainingSession session;
  final Exercise exercise;
  final TargetFace face;

  /// `false`, когда экран открыт тренером в режиме "дневник" —
  /// тренер никогда не владеет чужой тренировкой (C.2).
  final bool isOwnSession;

  TargetViewModel({
    required this.store,
    required this.session,
    required this.exercise,
    required this.face,
    this.isOwnSession = true,
  }) {
    _selectedIndex = session.shots.isEmpty ? -1 : session.shots.length - 1;
    if (isOwnSession) {
      _timer = Timer.periodic(const Duration(seconds: 1), (_) => _onTick());
    }
  }

  Timer? _timer;

  // ---- Навигация по выстрелам ----
  int _selectedIndex = -1;
  int get selectedIndex => _selectedIndex;

  /// Выстрелы ПОСЛЕ выбранного не отображаются ("они ещё не
  /// произошли") — ключевой принцип навигации (раздел 5 ТЗ).
  List<Shot> get visibleShots =>
      _selectedIndex < 0 ? const [] : session.shots.sublist(0, _selectedIndex + 1);

  Shot? get selectedShot =>
      _selectedIndex >= 0 && _selectedIndex < session.shots.length
          ? session.shots[_selectedIndex]
          : null;

  void selectIndex(int index) {
    if (session.shots.isEmpty) return;
    _selectedIndex = index.clamp(0, session.shots.length - 1);
    cancelEditing();
    notifyListeners();
  }

  /// Пролистывание двухпальцевым свайпом (B.4) — шаг пропорционален
  /// длине жеста, без "прыжков" между сериями, упирается в границы.
  void scrollByShots(double shotIndexDeltaFloat) {
    if (session.shots.isEmpty) return;
    final delta = shotIndexDeltaFloat.round();
    if (delta == 0) return;
    selectIndex(_selectedIndex + delta);
  }

  // ---- Режим отображения (нижняя панель, раздел 5 ТЗ) ----
  DisplayMode displayMode = DisplayMode.single;

  void cycleDisplayMode() {
    displayMode = DisplayMode.values[(displayMode.index + 1) % DisplayMode.values.length];
    notifyListeners();
  }

  // ---- canEdit — единая точка правды (C.2) ----
  bool get canEdit =>
      store.workMode == WorkMode.athlete &&
      isOwnSession &&
      session.status != SessionStatus.finished;

  /// Полоса управления тренировкой (старт/пауза/финиш + таймеры) —
  /// показывается только в режиме спортсмена, даже уже, чем canEdit
  /// (C.2: не зависит от session.status).
  bool get showTrainingControls => store.workMode == WorkMode.athlete && isOwnSession;

  /// Сколько после ухода на паузу ещё можно дописать выстрел.
  ///
  /// Решение пользователя: на паузе выстрелы не добавляются, но сразу
  /// после нажатия "Пауза" остаётся минута — чтобы успеть занести
  /// выстрел, который уже сделан, а пауза нажата следом. Просмотр и
  /// правка на паузе доступны без ограничений.
  static const Duration pauseAddGrace = Duration(minutes: 1);

  /// Момент начала текущей (незакрытой) паузы, либо null.
  DateTime? get currentPauseStartedAt {
    if (session.status != SessionStatus.paused) return null;
    for (final p in session.pauseIntervals.reversed) {
      if (p.resumedAt == null) return p.pausedAt;
    }
    return null;
  }

  /// Можно ли прямо сейчас записать новый выстрел.
  bool get canAddShotNow {
    if (!canEdit) return false;
    final pausedAt = currentPauseStartedAt;
    if (pausedAt == null) return true;
    return DateTime.now().difference(pausedAt) <= pauseAddGrace;
  }

  /// Сколько осталось от минутного окна на паузе (null — окна нет или
  /// тренировка не на паузе). Нужно для подписи в интерфейсе.
  Duration? get pauseGraceLeft {
    final pausedAt = currentPauseStartedAt;
    if (pausedAt == null) return null;
    final left = pauseAddGrace - DateTime.now().difference(pausedAt);
    return left.isNegative ? Duration.zero : left;
  }

  // ---- B.1 — состояния тренировки ----

  void start() {
    if (!canEdit) return;
    session = SessionLogic.start(session, DateTime.now());
    _persist();
  }

  void pause() {
    if (!canEdit) return;
    session = SessionLogic.pause(session, DateTime.now());
    _persist();
  }

  void resume() {
    if (!canEdit) return;
    session = SessionLogic.resume(session, DateTime.now());
    _persist();
  }

  void finish() {
    if (!canEdit) return;
    session = SessionLogic.finish(session, DateTime.now());
    _persist();
  }

  // ---- B.2/B.3 — таймеры ----
  Duration elapsed = Duration.zero;
  Duration? sinceLastShot;

  void _onTick() {
    if (session.status == SessionStatus.paused) {
      // На паузе таймеры стоят, но перерисовать раз в секунду всё равно
      // надо: истекает минутное окно, в которое ещё можно дописать
      // выстрел (canAddShotNow), и интерфейс должен это заметить сам.
      notifyListeners();
      return;
    }
    if (session.status != SessionStatus.running) return;
    elapsed = SessionLogic.elapsed(session, DateTime.now());
    sinceLastShot = SessionLogic.sinceLastShot(session, DateTime.now());
    notifyListeners();
  }

  void _refreshTimersNow() {
    elapsed = SessionLogic.elapsed(session, DateTime.now());
    sinceLastShot = SessionLogic.sinceLastShot(session, DateTime.now());
  }

  // ---- Текущая серия (упражнения со свободной структурой) ----

  /// Номер серии, в которую попадёт СЛЕДУЮЩИЙ выстрел.
  int get currentSeriesNo => SessionLogic.seriesNoFor(
        session,
        exercise,
        session.shots.length + 1,
        DateTime.now(),
      );

  /// Описание текущей серии. `null` — у упражнения нет структуры, и
  /// показывать в шапке нечего.
  SeriesSpec? get currentSeriesSpec => exercise.specFor(currentSeriesNo);

  /// Сколько выстрелов уже сделано в текущей серии.
  int get shotsInCurrentSeries {
    final no = currentSeriesNo;
    var n = 0;
    for (final s in session.shots) {
      if (s.seriesNo == no) n++;
    }
    return n;
  }

  /// Сколько времени осталось в серии, ограниченной временем.
  ///
  /// Отрицательное значение — время вышло. Это предупреждение, а не
  /// запрет: стрелять можно дальше, «опоздание» нигде не помечается —
  /// выстрел мог уйти за последнюю секунду (решение пользователя).
  Duration? get currentSeriesTimeLeft {
    final spec = currentSeriesSpec;
    final limit = spec?.timeLimit;
    if (limit == null) return null;
    final no = currentSeriesNo;
    // Отсчёт — от первого выстрела серии: именно он открывает её часы
    // (см. seriesNoFor). Первая серия начинается со стартом
    // тренировки, а серия, в которой ещё не стреляли, не начата —
    // показываем полное время.
    for (final s in session.shots) {
      if (s.seriesNo == no) {
        return limit - DateTime.now().difference(s.time);
      }
    }
    if (no > 1) return limit;
    final start = session.startedAt;
    if (start == null) return limit;
    return limit - DateTime.now().difference(start);
  }

  // ---- Добавление / правка выстрела ----

  bool isEditing = false;
  bool isAddingNew = false;
  double? _draftXMm;
  double? _draftYMm;
  Shot? _preEditSnapshot; // для отката по крестику

  double? get draftScore => _draftXMm == null
      ? null
      : scoreForRadius(math.sqrt(_draftXMm! * _draftXMm! + _draftYMm! * _draftYMm!), face);

  int? get draftClockHour {
    if (_draftXMm == null) return null;
    final tmp = Shot(
      id: '_draft',
      shotNumber: 0,
      seriesNo: 0,
      xMm: _draftXMm!,
      yMm: _draftYMm!,
      score: 0,
      time: DateTime.now(),
    );
    return clockDirection(tmp);
  }

  double get draftXMm => _draftXMm ?? 0;
  double get draftYMm => _draftYMm ?? 0;

  /// Угол черновика в градусах от 12 часов по часовой стрелке (0..360),
  /// то же соглашение, что у `Shot.angleDeg`. Нужен указателю
  /// направления на экране мишени.
  double? get draftAngleDeg {
    if (_draftXMm == null) return null;
    final deg = math.atan2(_draftXMm!, _draftYMm!) * 180 / math.pi;
    return deg < 0 ? deg + 360 : deg;
  }

  /// Целая часть результата черновика (габарит), либо null.
  int? get draftRing => draftScore?.floor();

  /// Десятая доля результата черновика, 0..9, либо null.
  int? get draftDecimal {
    final s = draftScore;
    if (s == null) return null;
    return ((s - s.floor()) * 10).round().clamp(0, 9);
  }

  /// Слайдер подбора десятых (A.6, замена степперов +/-).
  ///
  /// Двигает пробоину ВДОЛЬ ЕЁ ЛУЧА — угол сохраняется, меняется только
  /// расстояние до центра. Габарит при этом не меняется: слайдер
  /// работает внутри того кольца, в которое выстрел уже попал, и
  /// подбирает только десятую долю. Грубое позиционирование — жестом по
  /// мишени, точное — здесь.
  void setDraftDecimal(int decimal) {
    if (!isEditing || _draftXMm == null) return;
    final ring = draftRing;
    if (ring == null || ring < 1) return;
    final currentR = math.sqrt(_draftXMm! * _draftXMm! + _draftYMm! * _draftYMm!);
    // Тот же внутренний параметр поворота, что и в updateDraftPosition:
    // atan2(x, -y) с обратным преобразованием (sin / -cos).
    final angle = currentR == 0 ? 0.0 : math.atan2(_draftXMm!, -_draftYMm!);
    final newR = radiusForScore(ring, decimal.clamp(0, 9), face);
    _draftXMm = newR * math.sin(angle);
    _draftYMm = -newR * math.cos(angle);
    notifyListeners();
  }

  /// Компас на экране правки (A.6): задать угол напрямую, сохранив
  /// расстояние до центра — то есть не трогая результат.
  void setDraftAngleFromPoint(double xMm, double yMm) {
    if (!isEditing || _draftXMm == null) return;
    final currentR = math.sqrt(_draftXMm! * _draftXMm! + _draftYMm! * _draftYMm!);
    if (currentR == 0) return; // в самом центре угол не определён
    final angle = math.atan2(xMm, -yMm);
    _draftXMm = currentR * math.sin(angle);
    _draftYMm = -currentR * math.cos(angle);
    notifyListeners();
  }

  /// Начало правки существующего выстрела (жест "удержание" в зоне
  /// перемещения, либо кнопка "Переместить" по макетам — A.6).
  void beginMoveSelected() {
    if (!canEdit) return;
    final shot = selectedShot;
    if (shot == null) return;
    _preEditSnapshot = shot;
    _draftXMm = shot.xMm;
    _draftYMm = shot.yMm;
    isEditing = true;
    isAddingNew = false;
    notifyListeners();
  }

  /// Начало добавления нового выстрела (кнопка "Добавить" — A.6, либо
  /// тап в свободном месте мишени согласно жестовому слою реализации
  /// экрана). Стартует в центре, дальше правится перетаскиванием/
  /// степперами/компасом.
  void beginAddNew() {
    if (!canEdit) return;
    // Раньше здесь был жёсткий запрет на паузе (B.1). Теперь запрет мягче
    // и живёт в canAddShotNow: минуту после нажатия "Пауза" выстрел ещё
    // можно дописать (решение пользователя), дальше — нельзя, и интерфейс
    // подсказывает нажать "Продолжить".
    if (!canAddShotNow) return;
    _preEditSnapshot = null;
    _draftXMm = 0;
    _draftYMm = 0;
    isEditing = true;
    isAddingNew = true;
    notifyListeners();
  }

  /// Живое обновление координат во время перетаскивания/компаса.
  void updateDraftPosition(double xMm, double yMm) {
    if (!isEditing) return;
    _draftXMm = xMm;
    _draftYMm = yMm;
    notifyListeners();
  }

  // Степперы "Результат"/"Угол" (+/-) удалены по просьбе пользователя:
  // их заменили компас на самой мишени (setDraftAngleFromPoint) и
  // слайдер десятых (setDraftDecimal) — обе ручки выше.

  /// Подтверждение правки (галочка / "Сохранить" в AppBar по макетам).
  void confirmEdit() {
    if (!isEditing || _draftXMm == null) return;
    if (isAddingNew) {
      session = SessionLogic.addShot(
        session,
        exercise,
        face,
        _draftXMm!,
        _draftYMm!,
        DateTime.now(),
        idGenerator: () => _uuid.v4(),
        // Право записи на паузе уже проверено в beginAddNew через
        // canAddShotNow — здесь просто не даём SessionLogic отбросить
        // выстрел молча, иначе правка бы "сохранилась в никуда".
        allowDuringPause: canAddShotNow,
      );
      _selectedIndex = session.shots.length - 1;
    } else {
      final shot = _preEditSnapshot;
      if (shot != null) {
        final updated = shot.copyWith(
          xMm: _draftXMm,
          yMm: _draftYMm,
          score: scoreForRadius(
              math.sqrt(_draftXMm! * _draftXMm! + _draftYMm! * _draftYMm!), face),
          isManuallyEdited: true,
        );
        final idx = session.shots.indexWhere((s) => s.id == shot.id);
        if (idx != -1) {
          final list = [...session.shots];
          list[idx] = updated;
          session = session.copyWith(shots: list);
        }
      }
    }
    _finishEditing();
    _persist();
  }

  /// Отмена правки (крестик) — откатывает к позиции на момент начала
  /// удержания.
  void cancelEditing() {
    _finishEditing();
  }

  void _finishEditing() {
    isEditing = false;
    isAddingNew = false;
    _draftXMm = null;
    _draftYMm = null;
    _preEditSnapshot = null;
    notifyListeners();
  }

  /// Двухпальцевый жест немедленно отменяет активную правку (B.4).
  /// Второй палец на экране — это зум, а не правка.
  ///
  /// Отменяем И начатое добавление, и перемещение: пользователь
  /// сообщал, что попытка увеличить мишень оставляет на ней лишнюю
  /// пробоину.
  void onTwoFingerGestureStarted() {
    if (isEditing) cancelEditing();
  }

  /// Палец ушёл слишком далеко от точки удержания — значит это было
  /// не удержание, а начало жеста (прокрутка, зум, свайп страницы).
  ///
  /// Пользователь просил именно такой фильтр: «если палец двинулся за
  /// область, то отмена редактирования». Порог в пикселях задаётся
  /// жестовым слоем — он один знает про экран.
  void onGestureLeftHoldZone() {
    if (isAddingNew) cancelEditing();
  }

  // ---- B.5 — корзина ----

  void deleteSelected() {
    if (!canEdit) return;
    final shot = selectedShot;
    if (shot == null) return;
    session = SessionLogic.deleteShot(session, shot.id);
    _selectedIndex = session.shots.isEmpty ? -1 : (_selectedIndex - 1).clamp(0, session.shots.length - 1);
    cancelEditing();
    _persist();
  }

  void restoreFromTrash(String shotId) {
    if (!canEdit) return;
    session = SessionLogic.restoreShot(session, shotId, exercise);
    _persist();
  }

  void clearTrash() {
    if (!canEdit) return;
    session = SessionLogic.clearTrash(session);
    _persist();
  }

  // ---- Избранное ----
  void toggleFavorite(String shotId) {
    final idx = session.shots.indexWhere((s) => s.id == shotId);
    if (idx == -1) return;
    final list = [...session.shots];
    list[idx] = list[idx].copyWith(isFavorite: !list[idx].isFavorite);
    session = session.copyWith(shots: list);
    _persist();
  }

  // ---- Зум/пан ----
  double zoom = 1.0;
  double panX = 0;
  double panY = 0;

  void resetZoom() {
    zoom = 1.0;
    panX = 0;
    panY = 0;
    notifyListeners();
  }

  void applyScale(double scaleDelta, double focalDx, double focalDy) {
    // Потолок 6.9, а не 6.0 (просьба пользователя «ещё на 10-15%»):
    // на мишени 50 м десятка занимает считанные пиксели, и запаса не
    // хватало.
    zoom = (zoom * scaleDelta).clamp(1.0, 6.9);
    notifyListeners();
  }

  void applyPan(double dx, double dy) {
    panX += dx;
    panY += dy;
    notifyListeners();
  }

  // ---- Персист / lifecycle ----

  void _persist() {
    _refreshTimersNow();
    store.upsertSession(session);
    notifyListeners();
  }

  /// B.6 — "тренировка-призрак": вызывается из `dispose()` экрана.
  /// Пустая сессия НЕ попадает/не остаётся в истории.
  void disposeSession() {
    if (SessionLogic.isGhost(session)) {
      store.discardGhost(session.id);
    } else {
      store.upsertSession(session);
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    disposeSession();
    super.dispose();
  }
}
