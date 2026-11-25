import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../i18n/i18n.dart';
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
  /// в срок (выстрел за секунды до «Стоп» — не опоздание). Только в сетевом
  /// финале ([FinalRunController.allowGraceAfterStop]).
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
  const RunShot(this.who, this.index, this.shootOff, this.x, this.y, this.score,
      this.atSecond);

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

  /// Все люди-участники (спортсмен и, в финале с несколькими спортсменами,
  /// остальные). Боты — все прочие.
  final Set<String> humans;

  /// Ручной режим (финал ведёт тренер): подготовка, «Заряжай» и «Старт» не идут
  /// по таймеру, а подаются кнопкой «Далее» ([advance]). Время выстрелов
  /// засекается с «Старта»; «Стоп» тренер может подать раньше срока.
  final bool manual;

  /// Окно отметки выстрелов после «Стоп» включено. По ISSF 2026 выстрел, не
  /// отмеченный к команде «Стоп», не засчитывается — в одиночном (несетевом)
  /// финале окно выключено (по умолчанию). В совместном сетевом финале окно
  /// остаётся включённым: компенсация задержки сети, выстрел, сделанный в
  /// последний момент, не должен потеряться из-за медленного канала
  /// (владелец 24.11).
  final bool allowGraceAfterStop;
  final math.Random rng;
  final Map<String, BotShooter> bots;

  RunPhase phase = RunPhase.sighting;
  bool paused = false;

  /// Паузы по ISSF 2026 / владельцу 24.11: остановить время может спортсмен
  /// (неисправность) или судья, не больше [maxPauses] раз за финал и не
  /// дольше [maxPauseSeconds]; при превышении — сообщение ([pauseNotice]) и
  /// автопродолжение времени ([tick]).
  static const maxPauses = 2;
  static const maxPauseSeconds = 120;

  /// Сколько пауз осталось за финал.
  int pausesLeft = maxPauses;

  /// Сколько секунд осталось в текущей паузе (`null` — время не остановлено).
  int? pauseSecondsLeft;

  /// Сообщение для экрана: пауза отклонена или время продолжилось само.
  String? pauseNotice;

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

  /// Пристрелочные выстрелы ботов (не в зачёт): показываются бледно на их мишенях.
  final Map<String, List<(double, double)>> sightShots = {};

  /// Стартовые номера после жеребьёвки (id → номер с 1). По ISSF 2026
  /// жеребьёвка проводится после пристрелки, перед первой зачётной серией.
  final Map<String, int> startNumbers = {};

  /// План выстрелов бота в текущем раунде (id → момент в секундах раунда и
  /// длительности стадий «отдых/прицеливание/перезарядка»). Отзыв владельца
  /// 24.11: пауза бота не плоская — каждая стадия стоит времени и видна в
  /// статусе ([botStageOf]).
  final Map<String, List<({int at, BotStagePlan plan})>> _botShots = {};
  final Map<String, int> _roundFired = {};
  List<String> _shooters = [];

  FinalRunController({
    required this.format,
    required this.face,
    required this.engine,
    required this.userId,
    required this.bots,
    required this.rng,
    Set<String> otherHumans = const {},
    this.manual = false,
    this.allowGraceAfterStop = false,
  })  : humans = {userId, ...otherHumans},
        secondsLeft = format.sightingSeconds;

  /// Озвучка у всех участников / ведущий молчит (говорит главный жюри) — раздаётся гостям в снимке.
  bool voiceAll = false;
  bool hostSilent = false;

  /// Тир каждого участника финала (id → тир) и связь тиров (тир → [на связи, всего]); раздаётся в снимке.
  Map<String, String> sites = {};
  Map<String, List<int>> siteStatus = {};

  /// Кто остановил время (спортсмен при неисправности или судья); сбрасывается при продолжении.
  String? pausedBy;

  /// Публичный финал: итог уходит в таблицу чемпионов, ход виден на табло.
  bool isPublic = false;

  /// Начало токена главного из жюри (гость по нему узнаёт, что говорить должен он).
  String? chiefHint;

  FinalCompetitor get user => engine.byId(userId);

  /// Может ли человек сейчас ставить выстрел.
  bool get userCanShoot => canShootFor(userId);

  /// Может ли человек [id] сейчас ставить выстрел.
  bool canShootFor(String id) =>
      (phase == RunPhase.shooting || phase == RunPhase.grace) &&
      !paused &&
      _shooters.contains(id) &&
      stagedOf(id).length < shotsPerShooter;

  /// Секунд на отметку выстрелов после «Стоп».
  static const graceSeconds = 10;

  /// Окно после «Стоп» для отметки последних выстрелов; работает только при
  /// [allowGraceAfterStop]. В совместном финале ведущий увеличивает его на запас под
  /// задержку сети: выстрел, сделанный в последний момент, не должен потеряться из-за медленного канала.
  /// В одиночном финале окно выключено: выстрел после «Стоп» не засчитывается (ISSF 2026).
  int graceLimit = graceSeconds;

  /// Номер раунда для сети: выстрел, пришедший с опозданием из прошлого раунда, не засчитывается в новый.
  int get roundId => roundIndex * 2 + (inShootOff ? 1 : 0);

  /// Выстрелы человека в текущем раунде: можно убрать кнопкой «назад», в
  /// таблицу и движок уходят при закрытии раунда.
  final Map<String, List<({double x, double y, int t})>> _staged = {};

  List<({double x, double y, int t})> stagedOf(String id) =>
      _staged.putIfAbsent(id, () => []);

  /// Отмеченные выстрелы самого спортсмена.
  List<({double x, double y, int t})> get staged => stagedOf(userId);

  /// Сколько выстрелов осталось человеку в раунде.
  int get userShotsLeft =>
      _shooters.contains(userId) ? shotsPerShooter - staged.length : 0;

  /// Название раунда для экрана.
  String get roundLabel {
    if (inShootOff) return 'shootoff';
    if (phase == RunPhase.sighting) return 'sighting';
    if (roundIndex == 0 && format.hasOpenStage) return 'open';
    if (roundIndex < format.seriesShots.length)
      return 'series:${roundIndex + 1}';
    return 'single:${roundIndex - format.seriesShots.length + 1}';
  }

  /// Отзыв ac4c4f27: выстрелы, нащёлканные ДО «Готов» (в подготовке), —
  /// проба, а не пристрелка. При старте пристрелки со временем убираем их.
  void clearPreparationShots() {
    _staged.remove(userId);
    sightShots.remove(userId);
    notifyListeners();
  }

  /// Пропустить пристрелку (человек готов).
  void skipSighting() {
    if (phase != RunPhase.sighting) return;
    _beginLoading(5);
    notifyListeners();
  }

  /// Остановить время: спортсмен при неисправности или судья. По ISSF 2026
  /// не больше [maxPauses] раз за финал — лишний запрос отклоняется с
  /// сообщением.
  ///
  /// [counted] = false — команда «Стоп» тренера в ручном режиме ([advance]):
  /// это остановка раунда, а не пауза финала, лимит не расходует.
  /// Долгая (судьинская) пауза: время стоит, пока не нажали «Продолжить»,
  /// без автопродолжения через [maxPauseSeconds] (отзывы 7c58a3e2, 4013c8db).
  bool longPaused = false;

  void pause({bool counted = true, bool long = false}) {
    if (paused || phase == RunPhase.finished) return;
    if (counted) {
      if (pausesLeft <= 0) {
        if (long) {
          // Удержание паузы при исчерпанном лимите — принудительная долгая
          // пауза судьи: она не считается обычной и не идёт с отсчётом.
          paused = true;
          longPaused = true;
          pauseSecondsLeft = null;
          pauseNotice = tr('Долгая пауза: время пойдёт после «Продолжить»');
          log.add({'e': 'pause_long_forced', 't': clock});
          notifyListeners();
          return;
        }
        pauseNotice = tr('Лимит пауз исчерпан: не больше 2 за финал');
        log.add({'e': 'pause_denied', 't': clock});
        notifyListeners();
        return;
      }
      pausesLeft--;
      pauseSecondsLeft = long ? null : maxPauseSeconds;
    }
    longPaused = long;
    paused = true;
    pauseNotice = long ? tr('Долгая пауза: время пойдёт после «Продолжить»') : null;
    log.add({'e': 'pause', 't': clock});
    notifyListeners();
  }

  void resume() {
    pausedBy = null;
    pauseSecondsLeft = null;
    pauseNotice = null;
    longPaused = false;
    if (!paused) return;
    paused = false;
    log.add({'e': 'resume', 't': clock});
    notifyListeners();
  }

  /// Прошла одна секунда.
  void tick() {
    if (phase == RunPhase.finished) return;
    if (paused) {
      // Автопродолжение: пауза не держится дольше 120 с (ISSF 2026 / владелец 24.11).
      final left = pauseSecondsLeft;
      if (left != null && left <= 1) {
        resume();
        pauseNotice = tr('Пауза окончена — время пошло (лимит 120 с)');
        notifyListeners();
      } else {
        if (left != null) pauseSecondsLeft = left - 1;
        notifyListeners();
      }
      return;
    }
    switch (phase) {
      case RunPhase.sighting:
        // Отзыв cc403ad2: на пристрелке боты НЕ работают — пристрелка только
        // для своего прицеливания, чужие пробоины на ней не нужны.
        if (--secondsLeft <= 0 && !manual)
          _beginLoading(pauseAfterSighting + 5);
      case RunPhase.loading:
        if (--secondsLeft <= 0 && !manual) _beginRound();
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
        if (_humansDone()) {
          _endRound();
        } else if (secondsLeft > 0) {
          clock++;
          secondsLeft--;
        }
      // Время на отметку вышло, а выстрел не указан: дальше не идём — ждём результат («Промах» или исключение).
      case RunPhase.finished:
        break;
    }
    notifyListeners();
  }

  /// Кнопка тренера «Далее»: подготовка → «Заряжай» → «Старт» (пошёл отсчёт
  /// времени) → «Стоп». Работает в любом режиме, в обычном — как «пропустить».
  void advance() {
    // «Стоп» во время стрельбы — пауза (время и боты замирают), «Старт» продолжает ту же серию, а не переходит к
    // следующей: серия закрывается только по времени или когда все отстреляли.
    // Это команда раунда, а не пауза финала: лимит пауз ISSF не расходует.
    if (phase == RunPhase.shooting) {
      paused ? resume() : pause(counted: false);
      return;
    }
    if (paused) return;
    switch (phase) {
      case RunPhase.sighting:
        _beginLoading(5);
      case RunPhase.loading:
        // Идёт комментарий диктора: «Далее» подаёт «Заряжай» (не перескакиваем сразу к «Старт»).
        if (announcing) {
          secondsLeft = 5;
        } else {
          _beginRound();
        }
      case RunPhase.shooting:
        return; // обработано выше
      case RunPhase.grace:
        if (_humansDone()) {
          _endRound();
        } else {
          secondsLeft =
              0; // выстрел не указан — переход только после результата, «Промаха» или исключения
        }
      case RunPhase.finished:
        return;
    }
    notifyListeners();
  }

  /// Что сделает «Далее» сейчас (для подписи кнопки): load / start / stop / next.
  String get nextCommand => switch (phase) {
        RunPhase.sighting => 'load',
        RunPhase.loading => announcing ? 'load' : 'start',
        RunPhase.shooting => 'stop',
        RunPhase.grace => 'next',
        RunPhase.finished => '',
      };

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
    // Первая загрузка после пристрелки — жеребьёвка стартовых номеров
    // (ISSF 2026, п. 6.17.2 / владелец 24.11).
    if (phase == RunPhase.sighting) _drawStartNumbers();
    phase = RunPhase.loading;
    secondsLeft = seconds;
  }

  /// Жеребьёвка стартовых номеров: перемешиваем участников случайностью,
  /// выведенной из id финала, — при том же финале на всех устройствах номера
  /// совпадают (детерминированный [math.Random] с seed из [FinalFormat.id]).
  void _drawStartNumbers() {
    var seed = 0;
    for (final cu in format.id.codeUnits) {
      seed = (seed * 31 + cu) & 0x7fffffff;
    }
    final draw = math.Random(seed);
    final ids = [for (final c in engine.competitors) c.id]..shuffle(draw);
    for (var i = 0; i < ids.length; i++) {
      startNumbers[ids[i]] = i + 1;
    }
  }

  /// Стартовый номер участника (`null` — жеребьёвка ещё не проводилась).
  int? startNumberOf(String id) => startNumbers[id];

  List<String> _currentShooters() => inShootOff
      ? [for (final c in engine.shootOffShooters) c.id]
      : [for (final c in engine.active) c.id];

  void _beginRound() {
    // Переход с пристрелки на зачёт: пристрелочные выстрелы ботов с мишеней убираем.
    sightShots.clear();
    phase = RunPhase.shooting;
    roundSeconds = 0;
    _shooters = _currentShooters();
    _roundFired.clear();
    _botShots.clear();
    for (final l in _staged.values) {
      l.clear();
    }
    _doneTicks = 0;
    if (inShootOff) {
      shotsPerShooter = 1;
      roundLimit = format.singleSeconds;
    } else if (roundIndex < format.seriesShots.length) {
      shotsPerShooter = format.seriesShots[roundIndex];
      roundLimit = format.secondsForSeries(roundIndex);
    } else {
      shotsPerShooter = 1;
      roundLimit = format.singleSeconds;
    }
    // 3P: бот в каждой изготовке стреляет своим уровнем (отзыв владельца 24.11).
    final stance = _currentStance();
    for (final id in _shooters) {
      final bot = bots[id];
      if (bot == null) continue;
      bot.stance = stance;
      final plans = <({int at, BotStagePlan plan})>[];
      final slot = roundLimit / shotsPerShooter;
      for (var k = 0; k < shotsPerShooter; k++) {
        // Стадии «отдых/прицеливание/перезарядка» на этот выстрел (отзыв 24.11);
        // никто не стреляет на последней секунде раунда.
        final plan = bot.stagePause(slot.round());
        final t = (slot * k + plan.total + 1).round().clamp(1, roundLimit - 1);
        plans.add((at: t, plan: plan));
      }
      plans.sort((a, b) => a.at.compareTo(b.at));
      // Два выстрела одного стрелка не быстрее чем через 5 секунд
      // (отзыв 17.11); за пределы лимита раунда зазор не тянем —
      // выстрел позже лимита в любом случае не прозвучит.
      for (var k = 1; k < plans.length; k++) {
        if (plans[k].at < plans[k - 1].at + 5) {
          plans[k] = (at: math.min(plans[k - 1].at + 5, roundLimit - 1), plan: plans[k].plan);
        }
      }
      _botShots[id] = plans;
    }
  }

  /// Изготовка текущего раунда для 3P (отзыв владельца 24.11): бот по ней
  /// выбирает статистику ([BotShooter.byStance]). Перестрелка — стоя. Для
  /// остальных мишеней `null` — общий уровень бота.
  String? _currentStance() {
    if (face.code != 'rifle_50m') return null;
    if (inShootOff) return stanceStanding;
    if (roundIndex < 3) return stanceKneeling; // 3 серии с колена
    if (roundIndex < 6) return stanceProne; // 3 серии лёжа
    return stanceStanding; // 2 серии стоя и одиночные
  }

  /// Стадия бота в текущую секунду раунда: 'rest' | 'aim' | 'reload';
  /// '' — бот уже отстрелял в этом раунде либо это не бот.
  ///
  /// Отзыв владельца 24.11: экран показывает, чем занят бот — отдыхает,
  /// целится или перезаряжает, а выстрел — последняя стадия плана.
  String botStageOf(String id) {
    final plans = _botShots[id];
    if (plans == null) return '';
    for (final p in plans) {
      if (roundSeconds >= p.at) continue;
      if (roundSeconds >= p.at - p.plan.reload) return BotStage.reload.name;
      if (roundSeconds >= p.at - p.plan.reload - p.plan.aim) return BotStage.aim.name;
      return BotStage.rest.name;
    }
    return '';
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
    for (final id in List.of(_botShots.keys)) {
      final plans = _botShots[id]!;
      while (plans.isNotEmpty && plans.first.at <= roundSeconds) {
        plans.removeAt(0);
        final bot = bots[id]!;
        final (x, y) = bot.shotPoint(volatility: comebackLevel);
        _record(id, x, y, scoreForPoint(x, y, face));
      }
    }
  }

  /// Выстрел человека в точку (x, y) мм от центра мишени (y вверх).
  /// Возвращает результат с десятыми либо `null`, если сейчас нельзя.
  double? submitUserShot(double x, double y) => submitShotFor(userId, x, y);

  /// Кнопка «назад»: убирает последний отмеченный выстрел.
  bool undoUserShot() => undoShotFor(userId);

  /// То же для любого человека-участника (спортсмен на своём телефоне, тренер
  /// или помощник за другого спортсмена).
  double? submitShotFor(String id, double x, double y) {
    if (!humans.contains(id) || !canShootFor(id)) return null;
    stagedOf(id).add((x: x, y: y, t: clock));
    notifyListeners();
    return scoreForPoint(x, y, face);
  }

  bool undoShotFor(String id) {
    final l = stagedOf(id);
    if (l.isEmpty ||
        paused ||
        (phase != RunPhase.shooting && phase != RunPhase.grace)) return false;
    l.removeLast();
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
      if (humans.contains(id)) {
        if (stagedOf(id).length < shotsPerShooter) return false;
      } else if ((_botShots[id] ?? const []).isNotEmpty) {
        return false;
      }
    }
    return true;
  }

  /// Время на отметку после «Стоп» вышло, а у кого-то нет результата выстрела: ждём «Промах» или исключение.
  bool get awaitingResult =>
      phase == RunPhase.grace && secondsLeft <= 0 && !_humansDone();

  /// Люди, у которых не хватает результата выстрела (когда [awaitingResult]).
  List<String> get missingIds => awaitingResult
      ? [
          for (final id in _shooters)
            if (humans.contains(id) && stagedOf(id).length < shotsPerShooter) id
        ]
      : const [];

  /// «Промах»: выстрел не сделан по факту — записываем ноль (точка за пределами мишени).
  bool markMiss(String id) =>
      submitShotFor(id, face.faceRadiusMm * 1.5, 0) != null;

  /// Судья/тренер исключает финалиста: остаётся в таблице на месте выбывания, финал идёт дальше.
  bool exclude(String id) {
    if (!humans.contains(id) || phase == RunPhase.finished) return false;
    stagedOf(id).clear();
    if (!engine.withdraw(id)) return false;
    log.add({'e': 'exclude', 'who': id, 't': clock});
    _shooters.remove(id);
    if (engine.isFinished) phase = RunPhase.finished;
    notifyListeners();
    return true;
  }

  bool _humansDone() => _shooters
      .where(humans.contains)
      .every((id) => stagedOf(id).length >= shotsPerShooter);

  /// Время раунда вышло («Стоп»): если человек отметил не всё — короткое окно,
  /// но только в сетевом финале ([allowGraceAfterStop]); в одиночном выстрел
  /// после «Стоп» не засчитывается (ISSF 2026) — раунд закрывается сразу.
  void _stopRound() {
    if (allowGraceAfterStop && !_humansDone()) {
      phase = RunPhase.grace;
      secondsLeft = graceLimit;
      log.add({'e': 'stop', 't': clock});
    } else {
      _endRound();
    }
  }

  void _endRound() {
    // Отмеченные выстрелы людей уходят в зачёт; не отмеченные — нули.
    for (final id in _shooters.where(humans.contains)) {
      final l = stagedOf(id);
      for (final st in l) {
        if (engine.isFinished || !_stillInRound(id)) break;
        _record(id, st.x, st.y, scoreForPoint(st.x, st.y, face));
      }
      var fired = l.length;
      l.clear();
      while (
          fired < shotsPerShooter && !engine.isFinished && _stillInRound(id)) {
        _record(id, face.faceRadiusMm, 0, 0.0);
        log.add({'e': 'timeout', 'who': id, 't': clock});
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

  bool _stillInRound(String id) => inShootOff
      ? engine.phase == FinalPhase.shootOff &&
          engine.shootOffShooters.any((c) => c.id == id)
      : engine.phase == FinalPhase.match && engine.byId(id).active;

  /// Между сериями — комментарий диктора и «Заряжай»; при смене положения (колено → лёжа → стоя)
  /// пауза длиннее: смена изготовки и пристрелка по правилам.
  void _beginLoadingForNextRound() {
    final change = inShootOff ? null : format.changeAfterSeries[roundIndex - 1];
    _beginLoading(change ?? (announcerSeconds + 5));
  }

  /// Живая таблица: активные — по сумме (ISSF 2026: места на табло решает
  /// сумма на контрольной точке; средний выстрел — только подпись), включая
  /// уже отмеченные, но ещё не закрытые выстрелы спортсмена; выбывшие — ниже
  /// по местам. Пересчитывается после каждого выстрела.
  List<LiveRow> get live {
    final rows = <LiveRow>[];
    for (final c in engine.competitors) {
      final shots = [...c.shots];
      if (humans.contains(c.id) && c.active) {
        for (final st in stagedOf(c.id)) {
          shots.add(scoreForPoint(st.x, st.y, face));
        }
      }
      rows.add(LiveRow(c, shots));
    }
    final act = [
      for (final r in rows)
        if (r.c.active) r
    ]..sort((a, b) {
        // Отзыв 201f5e91: место в финале — по среднему выстрелу, а не по
        // сумме: у участников разное число выстрелов, сумма ставит вперёд
        // того, кто просто больше успел. Сумма — только при равном среднем.
        final byAvg = b.avg.compareTo(a.avg);
        return byAvg != 0 ? byAvg : b.total.compareTo(a.total);
      });
    final out = [
      for (final r in rows)
        if (!r.c.active) r
    ]..sort((a, b) => a.c.place!.compareTo(b.c.place!));
    return [...act, ...out];
  }

  /// Спортсмен выбыл и фиксирует результат: остаток финала (выстрелы ботов,
  /// выбывания, перестрелки) досчитывается сразу. Для активного спортсмена
  /// недоступно — его оставшиеся выстрелы пришлось бы обнулить.
  bool fastForward() {
    if (humans.any((h) => engine.byId(h).active) || phase == RunPhase.finished)
      return false;
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
            {
              'id': c.id,
              'name': c.name,
              'place': c.place,
              'total': c.total,
              'user': c.id == userId
            }
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

  double get total =>
      (shots.fold<double>(0, (a, b) => a + b) * 10).round() / 10;
  double get avg => shots.isEmpty ? 0 : total / shots.length;
}
