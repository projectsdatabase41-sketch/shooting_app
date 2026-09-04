import '../models/exercise.dart';
import '../models/series_spec.dart';
import '../models/shot.dart';
import '../models/target_face.dart';
import '../models/training_session.dart';
import 'scoring.dart';

/// Конечный автомат тренировки и связанная логика (часть B
/// logic-personalization-spec.md). Чистые функции — принимают
/// `TrainingSession`, возвращают новый (immutable, `copyWith`), не
/// мутируют аргумент. `TargetViewModel` — единственное место, где эти
/// функции вызываются и уведомляются слушатели.
///
/// B.1 — конечный автомат:
/// ```
/// notStarted --("Начать" ИЛИ первый addShot)--> running
/// running    --("Пауза")----------------------> paused
/// paused     --("Продолжить")------------------> running
/// running    --("Завершить")--------------------> finished
/// paused     --("Завершить")--------------------> finished
/// finished — терминальное состояние.
/// ```
class SessionLogic {
  SessionLogic._();

  static TrainingSession start(TrainingSession s, DateTime now) {
    if (s.status != SessionStatus.notStarted) return s;
    return s.copyWith(status: SessionStatus.running, startedAt: now);
  }

  static TrainingSession pause(TrainingSession s, DateTime now) {
    if (s.status != SessionStatus.running) return s; // допустим только из running
    return s.copyWith(
      status: SessionStatus.paused,
      pauseIntervals: [...s.pauseIntervals, PauseInterval(pausedAt: now)],
    );
  }

  static TrainingSession resume(TrainingSession s, DateTime now) {
    if (s.status != SessionStatus.paused) return s; // допустим только из paused
    final intervals = [...s.pauseIntervals];
    if (intervals.isNotEmpty && intervals.last.resumedAt == null) {
      intervals[intervals.length - 1] =
          intervals.last.copyWith(resumedAt: now);
    }
    return s.copyWith(status: SessionStatus.running, pauseIntervals: intervals);
  }

  static TrainingSession finish(TrainingSession s, DateTime now) {
    if (s.status != SessionStatus.running && s.status != SessionStatus.paused) {
      return s; // finish() допустим только из running/paused
    }
    var intervals = s.pauseIntervals;
    if (s.status == SessionStatus.paused &&
        intervals.isNotEmpty &&
        intervals.last.resumedAt == null) {
      // Последний интервал паузы закрывается тем же finishedAt, не
      // остаётся "открытым" (B.1).
      intervals = [...intervals];
      intervals[intervals.length - 1] =
          intervals.last.copyWith(resumedAt: now);
    }
    // finish() безвозвратно вызывает clearTrash() (B.1/B.5).
    return s.copyWith(
      status: SessionStatus.finished,
      finishedAt: now,
      pauseIntervals: intervals,
      trash: const [],
    );
  }

  /// `addShot()` при `paused`/`finished` — запрещено. При `notStarted` —
  /// неявно выполняет тот же переход, что и "Начать", ЗАТЕМ добавляет
  /// выстрел (важен порядок — иначе "время с последнего выстрела" в
  /// момент первого выстрела показало бы не 0).
  static TrainingSession addShot(
    TrainingSession s,
    Exercise exercise,
    TargetFace face,
    double xMm,
    double yMm,
    DateTime now, {
    String Function()? idGenerator,

    /// Разрешить запись выстрела, когда тренировка на паузе.
    ///
    /// По умолчанию false — базовое правило B.1 не изменилось. Флаг
    /// поднимает только `TargetViewModel`, и только внутри минутного
    /// окна сразу после нажатия "Пауза" (см. `canAddShotNow`): решение
    /// пользователя — дать время дописать уже сделанный выстрел.
    /// Политику окна держит вью-модель, здесь остаётся строгий дефолт.
    bool allowDuringPause = false,
  }) {
    if (s.status == SessionStatus.finished) {
      return s; // молча игнорируется — не exception, не диалог (B.1)
    }
    if (s.status == SessionStatus.paused && !allowDuringPause) {
      return s;
    }
    var session = s;
    if (session.status == SessionStatus.notStarted) {
      session = start(session, now);
    }
    final shotNumber = session.shots.length + 1;
    final seriesNo = seriesNoFor(session, exercise, shotNumber, now);
    final shot = Shot(
      id: idGenerator?.call() ?? '${now.microsecondsSinceEpoch}',
      shotNumber: shotNumber,
      seriesNo: seriesNo,
      xMm: xMm,
      yMm: yMm,
      score: 0,
      time: now,
      // Зачётность берётся из описания серии в момент выстрела и
      // дальше живёт на самом выстреле. Шаблон упражнения потом могут
      // переписать — уже отстрелянная тренировка меняться не должна.
      counts: exercise.countsSeries(seriesNo),
    );
    final scored = shot.copyWith(score: scoreFor(shot, face));
    return session.copyWith(shots: [...session.shots, scored]);
  }

  // ---- B.2 / B.3 — таймеры ----

  static Duration elapsed(TrainingSession s, DateTime now) {
    if (s.status == SessionStatus.notStarted || s.startedAt == null) {
      return Duration.zero;
    }
    final end = s.finishedAt ?? now;
    final total = end.difference(s.startedAt!);
    return total - totalPausedDuration(s, now);
  }

  static Duration totalPausedDuration(TrainingSession s, DateTime now) {
    var sum = Duration.zero;
    for (final interval in s.pauseIntervals) {
      final end = interval.resumedAt ??
          (s.status == SessionStatus.paused ? now : interval.pausedAt);
      sum += end.difference(interval.pausedAt);
    }
    return sum;
  }

  /// В какую серию попадает выстрел.
  ///
  /// У упражнения без описания серий всё как раньше: делим номер
  /// выстрела на размер серии. С описанием сложнее — серии разной
  /// длины, а часть из них ограничена не выстрелами, а временем
  /// (пристрелка 15 минут). Поэтому идём по описанию слева направо и
  /// «расходуем» его: выстрелами — по счётчику, временем — по часам
  /// от начала серии.
  ///
  /// Время вышло — серия считается закрытой, следующий выстрел уходит
  /// в следующую. Но это НЕ запрет: выстрел записывается, и пометки
  /// «опоздал» у него нет — он мог уйти за последнюю секунду.
  static int seriesNoFor(
    TrainingSession session,
    Exercise exercise,
    int shotNumber,
    DateTime now,
  ) {
    final specs = exercise.series;
    if (specs.isEmpty) {
      return ((shotNumber - 1) ~/ exercise.seriesSize) + 1;
    }

    var index = 0; // номер серии, с нуля
    var inSeries = 0; // сколько выстрелов уже в текущей серии
    DateTime? seriesStart = session.startedAt;

    // Раскладываем по сериям ВСЕ выстрелы заново, а последним —
    // новый. Раскладка одна и та же для старых и для нового: иначе
    // выстрел, которым серия закрылась, получал бы при записи один
    // номер, а при следующем пересчёте — другой.
    //
    // Проверка «серия закрыта» идёт ДО размещения выстрела, а не
    // после: выстрел, пришедший после истечения времени, принадлежит
    // уже следующей серии и считается в ней первым. Цикл, а не if, —
    // потому что закрыться может сразу несколько серий подряд
    // (пропущенная пристрелка длиной ноль выстрелов).
    for (final time in [for (final s in session.shots) s.time, now]) {
      seriesStart ??= time;
      // Последняя серия описания не закрывается: выстрелы сверх
      // задания остаются в ней, а не уходят в несуществующую
      // следующую.
      while (index < specs.length - 1 &&
          _seriesClosed(specs[index], inSeries, seriesStart!, time)) {
        index++;
        inSeries = 0;
        seriesStart = time;
      }
      inSeries++;
    }

    return index + 1;
  }

  /// Исчерпана ли серия к моменту [at]: по числу выстрелов или по часам.
  ///
  /// Время проверяется отдельно от выстрелов, потому что серия может
  /// истечь и БЕЗ них — пристрелка, в которой отстрелялись за пять
  /// минут из пятнадцати и просто ждут.
  static bool _seriesClosed(
    SeriesSpec spec,
    int inSeries,
    DateTime seriesStart,
    DateTime at,
  ) {
    if (spec.shotCount != null) return inSeries >= spec.shotCount!;
    if (spec.timeLimit != null) {
      return at.difference(seriesStart) >= spec.timeLimit!;
    }
    return false;
  }

  /// Обнуляется в момент addShot(), не останавливается при паузе
  /// намеренно, но не тикает после finished (B.3).
  static Duration? sinceLastShot(TrainingSession s, DateTime now) {
    final lastShotTime =
        s.shots.isEmpty ? s.startedAt : s.shots.last.time;
    if (lastShotTime == null) return null;
    if (s.status == SessionStatus.finished) {
      final end = s.finishedAt ?? now;
      return end.difference(lastShotTime);
    }
    return now.difference(lastShotTime);
  }

  // ---- B.5 — корзина ----

  static TrainingSession deleteShot(TrainingSession s, String shotId) {
    final shot = s.shots.firstWhere((sh) => sh.id == shotId, orElse: () => throw ArgumentError('shot not found'));
    final remaining = s.shots.where((sh) => sh.id != shotId).toList();
    return s.copyWith(shots: remaining, trash: [...s.trash, shot]);
  }

  /// Восстановление — в конец списка с пересчётом номера/серии
  /// (`shotNumber = shots.length + 1` на момент восстановления), не на
  /// старое место (B.5).
  static TrainingSession restoreShot(
    TrainingSession s,
    String shotId,
    Exercise exercise,
  ) {
    final shot = s.trash.firstWhere((sh) => sh.id == shotId, orElse: () => throw ArgumentError('shot not found in trash'));
    final remainingTrash = s.trash.where((sh) => sh.id != shotId).toList();
    final newNumber = s.shots.length + 1;
    // Серию считаем тем же правилом, что и при записи: у упражнения со
    // свободной структурой деление номера на размер серии врёт.
    // «Сейчас» для восстановленного выстрела — его собственное время:
    // он уже состоялся, и часы серии должны видеть именно его.
    final newSeries = seriesNoFor(s, exercise, newNumber, shot.time);
    // Зачётность у восстановленного выстрела берём заново: он мог
    // вернуться в другую серию, чем был.
    final restored = shot.copyWith(
      shotNumber: newNumber,
      seriesNo: newSeries,
      counts: exercise.countsSeries(newSeries),
    );
    return s.copyWith(shots: [...s.shots, restored], trash: remainingTrash);
  }

  static TrainingSession clearTrash(TrainingSession s) {
    return s.copyWith(trash: const []);
  }

  // ---- B.6 — "тренировка-призрак" ----

  /// `true`, если тренировку НЕ нужно сохранять в историю (пустая —
  /// вне зависимости от того, нажималась ли "Начать").
  static bool isGhost(TrainingSession s) => s.shots.isEmpty;
}
