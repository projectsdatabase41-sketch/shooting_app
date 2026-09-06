import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';
import '../logic/scoring.dart';
import '../logic/session_logic.dart';
import '../logic/shot_photo_detection.dart' show PixelPoint;
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

  /// Номер, который получит черновик при сохранении — для отображения
  /// НА пробоине ещё до подтверждения.
  ///
  /// У новой пробоины это `shots.length + 1`: `SessionLogic.addShot`
  /// всегда дописывает в конец списка независимо от того, какой выстрел
  /// сейчас выбран/виден (см. `beginAddNew` — оно не трогает
  /// `selectedIndex`). Раньше здесь ошибочно брался номер ВЫБРАННОГО
  /// выстрела — черновик новой пробоины показывал номер предыдущей.
  /// У уже существующей — её собственный номер, при перемещении он не
  /// меняется.
  int? get draftShotNumber {
    if (!isEditing) return null;
    if (isAddingNew) return session.shots.length + 1;
    return _preEditSnapshot?.shotNumber;
  }

  /// Угол черновика в градусах от 12 часов по часовой стрелке (0..360),
  /// то же соглашение, что у `Shot.angleDeg`. Нужен указателю
  /// направления на экране мишени.
  double? get draftAngleDeg {
    if (_draftXMm == null) return null;
    final deg = math.atan2(_draftXMm!, _draftYMm!) * 180 / math.pi;
    return deg < 0 ? deg + 360 : deg;
  }

  /// Луч, на котором стоит черновик. Запоминается, потому что ровно в
  /// центре угол не определён: без него пробоина, доведённая до нуля,
  /// при обратном ходе уезжала бы вверх, а не туда, откуда пришла.
  double? _draftAngleRad;

  double get _draftRadiusMm {
    final x = _draftXMm;
    final y = _draftYMm;
    if (x == null || y == null) return 0;
    return math.sqrt(x * x + y * y);
  }

  /// Сколько делений колеса помещается от центра до края бланка.
  int get maxDraftSteps {
    final step = face.decimalStepMm;
    if (step <= 0) return 0;
    return (face.faceRadiusMm / step).round();
  }

  /// Положение барабана при правке: чем больше, тем ближе к центру.
  ///
  /// Считается от ФАКТИЧЕСКОГО радиуса черновика, а не хранится
  /// отдельно — иначе после перетаскивания пальцем колесо показывало бы
  /// старое положение и первый же щелчок отбрасывал бы пробоину назад.
  int get draftInwardSteps {
    final step = face.decimalStepMm;
    if (step <= 0) return 0;
    final fromCentre = (_draftRadiusMm / step).round();
    return (maxDraftSteps - fromCentre).clamp(0, maxDraftSteps);
  }

  /// Колесо при правке: двигает пробоину ВДОЛЬ ЕЁ ЛУЧА в обе стороны —
  /// и к центру, и от него, на одну десятую долю за щелчок.
  ///
  /// Раньше колесо подбирало десятую долю ВНУТРИ того габарита, в
  /// который выстрел уже попал: значения 0..9 и никакого выхода за
  /// границу кольца. Из-за этого выстрел, поставленный на 9.0, крутился
  /// только в сторону 9.9, а к восьмёрке или к десятке его было не
  /// сдвинуть вовсе — и вдобавок первый же щелчок «примагничивал»
  /// пробоину к сетке десятых, теряя точку, выбранную пальцем.
  ///
  /// Теперь колесо работает приращением: берётся разница с текущим
  /// положением и прибавляется к фактическому радиусу. Габарит меняется
  /// сам собой, когда край пробоины переходит границу кольца, а дробная
  /// часть, заданная пальцем, сохраняется.
  void setDraftInwardSteps(int value) {
    if (!isEditing || _draftXMm == null) return;
    final step = face.decimalStepMm;
    if (step <= 0) return;

    final delta = value - draftInwardSteps; // + — к центру, − — от центра
    if (delta == 0) return;

    final currentR = _draftRadiusMm;
    if (currentR > 0) _draftAngleRad = math.atan2(_draftXMm!, -_draftYMm!);
    final angle = _draftAngleRad ?? 0.0;

    final newR = (currentR - delta * step).clamp(0.0, face.faceRadiusMm);
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

  /// Добавляет разом все пробоины, подтверждённые пользователем на фото
  /// (`PhotoScanScreen`) — их положение уже совмещено с фактическим
  /// отверстием ТАМ, на фото, поэтому повторная правка на самой мишени
  /// для каждой из них не нужна (решение пользователя: подтверждение на
  /// фото сразу ведёт к следующему фото, а не на экран правки).
  ///
  /// Возвращает, сколько выстрелов реально добавилось — на паузе после
  /// минутного окна (`canAddShotNow`) добавление молча останавливается,
  /// остаток списка теряется, и вызывающий код должен это показать.
  int addScannedShots(List<PixelPoint> pointsMm) {
    var added = 0;
    for (final p in pointsMm) {
      if (!canAddShotNow) break;
      session = SessionLogic.addShot(
        session,
        exercise,
        face,
        p.x,
        p.y,
        DateTime.now(),
        idGenerator: () => _uuid.v4(),
        allowDuringPause: canAddShotNow,
      );
      added++;
    }
    if (added > 0) {
      _selectedIndex = session.shots.length - 1;
      notifyListeners();
      _persist();
    }
    return added;
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

  /// Два пальца на мишени.
  ///
  /// Флаг читает рабочий стол: пока он поднят, страницы не листаются.
  /// Живёт во вью-модели, а не в самом холсте, потому что PageView
  /// находится выше по дереву и о пальцах на мишени иначе не узнает.
  bool multiTouch = false;

  void setMultiTouch(bool value) {
    if (multiTouch == value) return;
    multiTouch = value;
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

  /// Удаление КОНКРЕТНОГО выстрела по id — не обязательно того, что
  /// сейчас выбран.
  ///
  /// Нужен списку выстрелов: там кнопка удаления стоит у КАЖДОЙ строки,
  /// а `deleteSelected()` всегда бьёт по `selectedIndex` — это ровно то,
  /// из-за чего раньше убрали кнопку "удалить текущий" из шапки списка
  /// (била не по той строке, на которую смотрел палец).
  void deleteShot(String shotId) {
    if (!canEdit) return;
    final keepId = selectedShot?.id;
    session = SessionLogic.deleteShot(session, shotId);
    if (isEditing && _preEditSnapshot?.id == shotId) cancelEditing();
    if (keepId != null && keepId != shotId) {
      final idx = session.shots.indexWhere((s) => s.id == keepId);
      _selectedIndex = idx >= 0 ? idx : (session.shots.isEmpty ? -1 : session.shots.length - 1);
    } else {
      _selectedIndex = session.shots.isEmpty ? -1 : _selectedIndex.clamp(0, session.shots.length - 1);
    }
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
