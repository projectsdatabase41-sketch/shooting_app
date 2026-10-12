import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../logic/scoring.dart';
import '../models/target_face.dart';
import 'bot.dart';
import 'final_engine.dart';

enum RunPhase {
  /// 5 минут подготовки и пристрелки (в зачёт не идёт).
  sighting,

  /// Короткая пауза между командами «Заряжай» и «Старт».
  loading,

  /// Идёт серия, одиночный выстрел или перестрелка.
  shooting,

  /// После команды «Стоп»: спортсмен ещё может отметить выстрел, сделанный
  /// в срок (выстрел за секунды до «Стоп» — не опоздание).
  grace,
  finished,
}

/// Один записанный выстрел (для таблицы и записи хода финала).
class RunShot {
  final String who;
  final int index; // номер зачётного выстрела (с 0) или перестрелочного
  final bool shootOff;
  final double x;
  final double y;
  final double score;
  final int atSecond; // время от начала зачётной части
  const RunShot(this.who, this.index, this.shootOff, this.x, this.y, this.score, this.atSecond);

  Map<String, dynamic> toJson() => {
        'who': who,
        'i': index,
        if (shootOff) 'so': true,
        'x': double.parse(x.toStringAsFixed(2)),
        'y': double.parse(y.toStringAsFixed(2)),
        's': score,
        't': atSecond,
      };
}

/// Ход финала в реальном времени: подготовка → серии → одиночные выстрелы →
/// выбывания и перестрелки. Время идёт «секундами симуляции»: [tick] — одна
/// секунда; таймер экрана вызывает его раз в секунду (быстрее — при ускорении),
/// тесты вызывают напрямую. Боты стреляют настоящими точками попадания.
///
/// Человек, не успевший выстрелить за время, получает нули за невыстрелянные
/// выстрелы (как в правилах: невыстрелянный в срок выстрел не засчитывается).
/// Кнопка «Пауза» — единственное отступление от строгих правил; паузы пишутся
/// в журнал.
class FinalRunController extends ChangeNotifier {
  final FinalFormat format;
  final TargetFace face;
  final FinalEngine engine;
  final String userId;
  final math.Random rng;
  final Map<String, BotShooter> bots;

  RunPhase phase = RunPhase.sighting;
  bool paused = false;

  /// Секунд до конца этапа (подготовка / «заряжай»).
  int secondsLeft;

  /// Секунд прошло в текущем раунде.
  int roundSeconds = 0;

  /// Сколько секунд на текущий раунд.
  int roundLimit = 0;

  /// Номер текущего раунда зачётной части (с 0); перестрелка — отдельный счёт.
  int roundIndex = 0;
  bool inShootOff = false;

  /// Сколько выстрелов в этом раунде делает каждый стрелок (5 или 1).
  int shotsPerShooter = 0;

  int clock = 0; // секунды зачётной части

  /// Все выстрелы финала.
  final List<RunShot> shots = [];

  /// Журнал событий (паузы, выбывания) для записи в базу.
  final List<Map<String, dynamic>> log = [];

  final Map<String, List<int>> _botTimes = {}; // секунды раунда, когда стреляет бот
  final Map<String, int> _roundFired = {};
  List<String> _shooters = [];

  FinalRunController({
    required this.format,
    required this.face,
    required this.engine,
    required this.userId,
    required this.bots,
    required this.rng,
  }) : secondsLeft = format.sightingSeconds;

  FinalCompetitor get user => engine.byId(userId);

  /// Может ли человек сейчас ставить выстрел.
  bool get userCanShoot =>
      (phase == RunPhase.shooting || phase == RunPhase.grace) &&
      !paused &&
      _shooters.contains(userId) &&
      staged.length < shotsPerShooter;

  /// Секунд на отметку выстрелов после «Стоп».
  static const graceSeconds = 10;

  /// Выстрелы человека в текущем раунде: можно убрать кнопкой «назад», в
  /// таблицу и движок уходят при закрытии раунда.
  final List<({double x, double y, int t})> staged = [];

  /// Сколько выстрелов осталось человеку в раунде.
  int get userShotsLeft =>
      _shooters.contains(userId) ? shotsPerShooter - staged.length : 0;

  /// Название раунда для экрана.
  String get roundLabel {
    if (inShootOff) return 'shootoff';
    if (roundIndex == 0 && format.hasOpenStage) return 'open';
    if (roundIndex < format.seriesShots.length) return 'series:${roundIndex + 1}';
    return 'single:${roundIndex - format.seriesShots.length + 1}';
  }

  /// Пропустить пристрелку (человек готов).
  void skipSighting() {
    if (phase != RunPhase.sighting) return;
    _beginLoading(5);
    notifyListeners();
  }

  void pause() {
    if (paused || phase == RunPhase.finished) return;
    paused = true;
    log.add({'e': 'pause', 't': clock});
    notifyListeners();
  }

  void resume() {
    if (!paused) return;
    paused = false;
    log.add({'e': 'resume', 't': clock});
    notifyListeners();
  }

  /// Прошла одна секунда.
  void tick() {
    if (paused || phase == RunPhase.finished) return;
    switch (phase) {
      case RunPhase.sighting:
        if (--secondsLeft <= 0) _beginLoading(pauseAfterSighting + 5);
      case RunPhase.loading:
        if (--secondsLeft <= 0) _beginRound();
      case RunPhase.shooting:
        clock++;
        roundSeconds++;
        _fireDueBots();
        if (roundSeconds >= roundLimit) {
          _stopRound();
        } else if (_allDone()) {
          if (++_doneTicks >= doneHoldSeconds) _stopRound();
        } else {
          _doneTicks = 0;
        }
      case RunPhase.grace:
        clock++;
        if (--secondsLeft <= 0 || staged.length >= shotsPerShooter) _endRound();
      case RunPhase.finished:
        break;
    }
    notifyListeners();
  }

  /// ISSF 6.17.2: после пристрелки 60 с до первой серии.
  static const pauseAfterSighting = 60;

  /// После «Стоп» диктор 15–20 с комментирует рейтинг, потом «Заряжай» (5 с).
  static const announcerSeconds = 18;

  /// Идёт комментарий диктора (до команды «Заряжай»).
  bool get announcing => phase == RunPhase.loading && secondsLeft > 5;

  /// Раунд заканчивается досрочно, когда все отстреляли и спокойно подождали.
  static const doneHoldSeconds = 3;
  int _doneTicks = 0;

  void _beginLoading(int seconds) {
    phase = RunPhase.loading;
    secondsLeft = seconds;
  }

  List<String> _currentShooters() => inShootOff
      ? [for (final c in engine.shootOffShooters) c.id]
      : [for (final c in engine.active) c.id];

  void _beginRound() {
    phase = RunPhase.shooting;
    roundSeconds = 0;
    _shooters = _currentShooters();
    _roundFired.clear();
    _botTimes.clear();
    staged.clear();
    _doneTicks = 0;
    if (inShootOff) {
      shotsPerShooter = 1;
      roundLimit = format.singleSeconds;
    } else if (roundIndex < format.seriesShots.length) {
      shotsPerShooter = format.seriesShots[roundIndex];
      roundLimit = (roundIndex == 0 && format.hasOpenStage) ? format.openSeconds : format.seriesSeconds;
    } else {
      shotsPerShooter = 1;
      roundLimit = format.singleSeconds;
    }
    for (final id in _shooters) {
      final bot = bots[id];
      if (bot == null) continue;
      final times = <int>[];
      for (var k = 0; k < shotsPerShooter; k++) {
        // Равномерно по времени серии с разбросом; никто не стреляет на последней секунде.
        final slot = roundLimit / shotsPerShooter;
        final t = (slot * k + bot.delaySeconds(slot.round()) + 1).round().clamp(1, roundLimit - 1);
        times.add(t);
      }
      times.sort();
      // Два выстрела одного стрелка не быстрее чем через 5 секунд.
      for (var k = 1; k < times.length; k++) {
        if (times[k] < times[k - 1] + 5) times[k] = times[k - 1] + 5;
      }
      _botTimes[id] = times;
    }
  }

  /// Сила камбэков ботов (0.15…1): чем лучше стреляет спортсмен относительно
  /// ботов, тем реже они отыгрываются.
  double get comebackLevel {
    final mine = user.shots;
    if (mine.length < 3) return 1;
    final botAvgs = [
      for (final c in engine.competitors)
        if (!c.isUser && c.shots.isNotEmpty) c.total / c.shots.length
    ];
    if (botAvgs.isEmpty) return 1;
    final d = mine.fold<double>(0, (a, b) => a + b) / mine.length -
        botAvgs.reduce((a, b) => a + b) / botAvgs.length;
    return (1 - d / 0.5).clamp(0.15, 1.0);
  }

  void _fireDueBots() {
    for (final id in List.of(_botTimes.keys)) {
      final times = _botTimes[id]!;
      while (times.isNotEmpty && times.first <= roundSeconds) {
        times.removeAt(0);
        final bot = bots[id]!;
        final (x, y) = bot.shotPoint(volatility: comebackLevel);
        _record(id, x, y, scoreForPoint(x, y, face));
      }
    }
  }

  /// Выстрел человека в точку (x, y) мм от центра мишени (y вверх).
  /// Возвращает результат с десятыми либо `null`, если сейчас нельзя.
  double? submitUserShot(double x, double y) {
    if (!userCanShoot) return null;
    staged.add((x: x, y: y, t: clock));
    notifyListeners();
    return scoreForPoint(x, y, face);
  }

  /// Кнопка «назад»: убирает последний отмеченный выстрел.
  bool undoUserShot() {
    if (staged.isEmpty || paused || (phase != RunPhase.shooting && phase != RunPhase.grace)) return false;
    staged.removeLast();
    notifyListeners();
    return true;
  }

  void _record(String id, double x, double y, double score) {
    final c = engine.byId(id);
    final idx = inShootOff ? c.shootoff.length : c.shots.length;
    shots.add(RunShot(id, idx, inShootOff, x, y, score, clock));
    _roundFired[id] = (_roundFired[id] ?? 0) + 1;
    final wasActive = {for (final a in engine.active) a.id};
    engine.submit(id, score);
    for (final a in wasActive) {
      final p = engine.byId(a).place;
      if (p != null) log.add({'e': 'place', 'who': a, 'place': p, 't': clock});
    }
  }

  bool _allDone() {
    for (final id in _shooters) {
      if (id == userId) {
        if (staged.length < shotsPerShooter) return false;
      } else if ((_botTimes[id] ?? const []).isNotEmpty) {
        return false;
      }
    }
    return true;
  }

  /// Время раунда вышло («Стоп»): если человек отметил не всё — короткое окно.
  void _stopRound() {
    if (_shooters.contains(userId) && staged.length < shotsPerShooter) {
      phase = RunPhase.grace;
      secondsLeft = graceSeconds;
      log.add({'e': 'stop', 't': clock});
    } else {
      _endRound();
    }
  }

  void _endRound() {
    // Отмеченные выстрелы человека уходят в зачёт; не отмеченные — нули.
    if (_shooters.contains(userId)) {
      for (final st in staged) {
        if (engine.isFinished || !_userStillInRound()) break;
        _record(userId, st.x, st.y, scoreForPoint(st.x, st.y, face));
      }
      var fired = staged.length;
      staged.clear();
      while (fired < shotsPerShooter && !engine.isFinished && _userStillInRound()) {
        _record(userId, face.faceRadiusMm, 0, 0.0);
        log.add({'e': 'timeout', 'who': userId, 't': clock});
        fired++;
      }
    }
    if (engine.isFinished) {
      phase = RunPhase.finished;
      return;
    }
    // Раунд зачётной части закончен (даже если за ним следует перестрелка).
    if (!inShootOff) roundIndex++;
    inShootOff = engine.phase == FinalPhase.shootOff;
    _beginLoadingForNextRound();
  }

  bool _userStillInRound() => inShootOff
      ? engine.phase == FinalPhase.shootOff && engine.shootOffShooters.any((c) => c.id == userId)
      : engine.phase == FinalPhase.match && user.active;

  void _beginLoadingForNextRound() => _beginLoading(announcerSeconds + 5);

  /// Живая таблица: активные — по среднему выстрелу (у всех разное число
  /// выстрелов, пока раунд идёт), включая уже отмеченные, но ещё не закрытые
  /// выстрелы спортсмена; выбывшие — ниже по местам. Пересчитывается после
  /// каждого выстрела.
  List<LiveRow> get live {
    final rows = <LiveRow>[];
    for (final c in engine.competitors) {
      final shots = [...c.shots];
      if (c.isUser && c.active) {
        for (final st in staged) {
          shots.add(scoreForPoint(st.x, st.y, face));
        }
      }
      rows.add(LiveRow(c, shots));
    }
    final act = [for (final r in rows) if (r.c.active) r]
      ..sort((a, b) {
        final byAvg = b.avg.compareTo(a.avg);
        return byAvg != 0 ? byAvg : b.total.compareTo(a.total);
      });
    final out = [for (final r in rows) if (!r.c.active) r]..sort((a, b) => a.c.place!.compareTo(b.c.place!));
    return [...act, ...out];
  }

  /// Спортсмен выбыл и фиксирует результат: остаток финала (выстрелы ботов,
  /// выбывания, перестрелки) досчитывается сразу. Для активного спортсмена
  /// недоступно — его оставшиеся выстрелы пришлось бы обнулить.
  bool fastForward() {
    if (user.active || phase == RunPhase.finished) return false;
    paused = false;
    var guard = 0;
    while (phase != RunPhase.finished && guard++ < 200000) {
      tick();
    }
    return phase == RunPhase.finished;
  }

  /// Итоговые данные для записи в базу.
  Map<String, dynamic> toRecord() => {
        'format': format.id,
        'face': face.code,
        'finishedAt': DateTime.now().toUtc().toIso8601String(),
        'standings': [
          for (final c in engine.standings)
            {'id': c.id, 'name': c.name, 'place': c.place, 'total': c.total, 'user': c.id == userId}
        ],
        'shots': [for (final s in shots) s.toJson()],
        'log': log,
      };
}

/// Строка живой таблицы финала.
class LiveRow {
  final FinalCompetitor c;
  final List<double> shots;
  LiveRow(this.c, this.shots);

  double get total => (shots.fold<double>(0, (a, b) => a + b) * 10).round() / 10;
  double get avg => shots.isEmpty ? 0 : total / shots.length;
}
