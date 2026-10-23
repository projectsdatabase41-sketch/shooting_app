import 'dart:math' as math;

/// Формат финала по правилам ISSF.
///
/// Источник: ISSF Rule Book 2026 (2025, второй тираж 07/2026), п. 6.17.2
/// «Finals — 10 m Air Rifle and 10 m Air Pistol, Men and Women»:
/// - 8 финалистов, десятые доли очка (decimal scoring);
/// - две серии по 5 зачётных выстрелов, на каждую 250 с;
/// - затем 14 одиночных выстрелов, на каждый 50 с, по команде;
/// - выбывание самого слабого после 12-го выстрела и далее после каждых двух
///   (14, 16, 18, 20, 22) — места 8…3; после 24-го выстрела — 2 и 1 место;
/// - ничья за выбывание или за золото — одиночные перестрелочные выстрелы
///   до разрыва ничьей;
/// - перед зачётом 5 минут подготовки и пристрелки (без ограничения числа).
/// Время в правилах названо ориентировочным.
class FinalFormat {
  final String id;

  /// Название — ключ перевода.
  final String nameKey;

  /// Мишень (код из `TargetFace`).
  final String faceCode;
  final int finalists;
  final List<int> seriesShots;
  final int singleShots;
  final int seriesSeconds;
  final int singleSeconds;
  final int sightingSeconds;

  /// После скольких выстрелов выбывает самый слабый (место = finalists − индекс).
  final List<int> eliminationAfter;

  /// Сколько выбывает на каждой контрольной точке (по умолчанию по одному).
  /// 50 м из трёх положений: после 30-го выстрела сразу двое (п. 6.17.3).
  final List<int>? eliminationCounts;

  /// Открытый этап без команд (лёжа и с колена): первая «серия» из
  /// [seriesShots] идёт [openSeconds] секунд, стреляют в своём темпе.
  final int openSeconds;

  /// Время каждой серии отдельно (если положения разные): с колена 200 с, лёжа 150 с, стоя 250 с.
  /// `null` — у всех серий [seriesSeconds].
  final List<int>? seriesSecondsList;

  /// Смена изготовки: после серии с номером (с нуля) — сколько секунд занимает смена и пристрелка.
  final Map<int, int> changeAfterSeries;

  /// Размеры блоков для разрыва ничьей по счёту при выбывании двоих
  /// (последняя серия, предыдущая серия, затем отдельные выстрелы назад).
  final List<int> countbackBlocks;

  const FinalFormat({
    required this.id,
    required this.nameKey,
    required this.faceCode,
    this.finalists = 8,
    this.seriesShots = const [5, 5],
    this.singleShots = 14,
    this.seriesSeconds = 250,
    this.singleSeconds = 50,
    this.sightingSeconds = 300,
    this.eliminationAfter = const [12, 14, 16, 18, 20, 22],
    this.eliminationCounts,
    this.openSeconds = 0,
    this.seriesSecondsList,
    this.changeAfterSeries = const {},
    this.countbackBlocks = const [],
  });

  int eliminationsAt(int checkpoint) =>
      eliminationCounts == null ? 1 : eliminationCounts![checkpoint];

  bool get hasOpenStage => openSeconds > 0;

  int get totalShots => seriesShots.fold(0, (a, b) => a + b) + singleShots;

  /// Лимит времени на выстрел с номером [shotIndex] (с нуля): в сериях —
  /// общий лимит серии, дальше — на каждый выстрел.
  /// Лимит времени серии [i] (с нуля).
  int secondsForSeries(int i) {
    if (i == 0 && hasOpenStage) return openSeconds;
    final l = seriesSecondsList;
    return (l != null && i < l.length) ? l[i] : seriesSeconds;
  }

  int secondsForShot(int shotIndex) {
    var left = shotIndex;
    for (var i = 0; i < seriesShots.length; i++) {
      if (left < seriesShots[i]) return secondsForSeries(i);
      left -= seriesShots[i];
    }
    return singleSeconds;
  }

  /// Пневматическая винтовка 10 м (мужчины и женщины).
  static const airRifle10m = FinalFormat(
    id: 'air_rifle_10m',
    nameKey: /*tr*/ 'Финал: пневматическая винтовка 10 м',
    faceCode: 'rifle_10m',
  );

  /// Пневматический пистолет 10 м — тот же формат (п. 6.17.2).
  static const airPistol10m = FinalFormat(
    id: 'air_pistol_10m',
    nameKey: /*tr*/ 'Финал: пневматический пистолет 10 м',
    faceCode: 'pistol_10m',
  );

  /// Винтовка 50 м, три положения (п. 6.17.3): по 15 выстрелов с колена (3×5 по 200 с),
  /// лёжа (3×5 по 150 с; смена и пристрелка 7 мин) и стоя (2×5 по 250 с; смена и пристрелка 9 мин).
  /// После 40-го выстрела выбывают двое, затем 5 одиночных по 50 с, после каждого выбывает
  /// самый слабый. Всего 45 выстрелов.
  static const rifle3p50m = FinalFormat(
    id: 'rifle_3p_50m',
    nameKey: /*tr*/ 'Финал: винтовка 50 м, три положения',
    faceCode: 'rifle_50m',
    seriesShots: [5, 5, 5, 5, 5, 5, 5, 5],
    seriesSecondsList: [200, 200, 200, 150, 150, 150, 250, 250],
    changeAfterSeries: {2: 420, 5: 540},
    singleShots: 5,
    eliminationAfter: [40, 41, 42, 43, 44],
    eliminationCounts: [2, 1, 1, 1, 1],
    countbackBlocks: [5, 5],
  );

  /// Свой финал (конструктор): серии, одиночные выстрелы и время задаёт
  /// пользователь. Выбывание — по одному после каждых [step] выстрелов так,
  /// чтобы к последнему выстрелу остались двое (как в п. 6.17.2).
  /// Возвращает `null`, если выстрелов слишком мало для восьми финалистов.
  static FinalFormat? custom({
    required String faceCode,
    required int series,
    required int perSeries,
    required int singles,
    required int seriesSeconds,
    required int singleSeconds,
    required int step,
  }) {
    final total = series * perSeries + singles;
    const eliminations = 6; // из восьми остаётся двое
    final first = total - step * eliminations;
    if (first < 1 || step < 1 || total < 1) return null;
    return FinalFormat(
      id: 'custom',
      nameKey: /*tr*/ 'Свой финал',
      faceCode: faceCode,
      seriesShots: [for (var i = 0; i < series; i++) perSeries],
      singleShots: singles,
      seriesSeconds: seriesSeconds,
      singleSeconds: singleSeconds,
      eliminationAfter: [for (var i = 0; i < eliminations; i++) first + step * i],
    );
  }

  static const all = [airRifle10m, airPistol10m, rifle3p50m];
}

enum FinalPhase { match, shootOff, finished }

/// Участник финала: человек или бот.
class FinalCompetitor {
  final String id;
  final String name;
  final bool isUser;

  /// Зачётные выстрелы (десятые доли).
  final List<double> shots = [];

  /// Перестрелочные выстрелы (в зачёт не идут).
  final List<double> shootoff = [];

  /// Итоговое место; `null`, пока участник в борьбе.
  int? place;

  FinalCompetitor(this.id, this.name, {this.isUser = false});

  bool get active => place == null;

  /// Сумма первых [n] выстрелов (округление до десятых — без хвостов float).
  double totalAt(int n) =>
      (shots.take(n).fold<double>(0, (a, b) => a + b) * 10).round() / 10;

  double get total => totalAt(shots.length);
}

/// Ход финала: выстрелы, выбывание, перестрелки, места. Время и звуковые
/// команды — на экране; здесь только правила подсчёта и выбывания.
class FinalEngine {
  final FinalFormat format;
  final List<FinalCompetitor> competitors;
  FinalPhase phase = FinalPhase.match;

  int _checkpoint = 0; // сколько контрольных точек (выбывания + конец) пройдено
  int _elimInCp = 0; // сколько уже выбыло на текущей контрольной точке
  List<FinalCompetitor> _tied = [];
  int _soRound = 0;
  bool _soForGold = false;
  int _soPlace = 0;

  FinalEngine(this.format, this.competitors) {
    if (competitors.length != format.finalists) {
      throw ArgumentError('В финале должно быть ${format.finalists} участников');
    }
  }

  FinalCompetitor byId(String id) => competitors.firstWhere((c) => c.id == id);

  List<FinalCompetitor> get active => [for (final c in competitors) if (c.active) c];

  /// Контрольные точки: после этих выстрелов решается место.
  List<int> get _checkpoints => [...format.eliminationAfter, format.totalShots];

  /// Кто сейчас должен стрелять в перестрелке.
  List<FinalCompetitor> get shootOffShooters => List.unmodifiable(_tied);

  bool get isFinished => phase == FinalPhase.finished;

  /// Сколько выстрелов сделано всеми активными (минимум).
  int get roundShots => active.map((c) => c.shots.length).fold(1 << 30, math.min);

  /// Принять выстрел [score] участника [id].
  void submit(String id, double score) {
    final c = byId(id);
    switch (phase) {
      case FinalPhase.finished:
        throw StateError('Финал окончен');
      case FinalPhase.match:
        if (!c.active) throw StateError('${c.name} уже выбыл');
        if (c.shots.length >= format.totalShots) throw StateError('Все выстрелы сделаны');
        c.shots.add(score);
        _advance();
      case FinalPhase.shootOff:
        if (!_tied.contains(c)) throw StateError('${c.name} не участвует в перестрелке');
        if (c.shootoff.length > _soRound) throw StateError('${c.name} уже выстрелил в этом круге');
        c.shootoff.add(score);
        if (_tied.every((t) => t.shootoff.length > _soRound)) _resolveShootOff();
    }
  }

  void _advance() {
    while (phase == FinalPhase.match && _checkpoint < _checkpoints.length) {
      final n = _checkpoints[_checkpoint];
      final act = active;
      if (act.any((c) => c.shots.length < n)) return;
      final last = _checkpoint == _checkpoints.length - 1;
      if (last) {
        final sorted = [...act]..sort((a, b) => b.totalAt(n).compareTo(a.totalAt(n)));
        final best = sorted.first.totalAt(n);
        final leaders = [for (final c in sorted) if (c.totalAt(n) == best) c];
        if (leaders.length > 1) {
          _startShootOff(leaders, forGold: true, place: 1);
          return;
        }
        sorted[0].place = 1;
        sorted[1].place = 2;
        phase = FinalPhase.finished;
        _checkpoint++;
        return;
      }
      final k = format.eliminationsAt(_checkpoint);
      final lowest = act.map((c) => c.totalAt(n)).reduce(math.min);
      final lows = [for (final c in act) if (c.totalAt(n) == lowest) c];
      final place = format.finalists - [for (final c in competitors) if (!c.active) c].length;
      if (lows.length == 1) {
        lows.first.place = place;
      } else if (lows.length == 2 && k == 2 && _elimInCp == 0 && _countback(lows[0], lows[1], n) != 0) {
        // Двое с равной суммой при выбывании двоих: худший по счёту серий — 8-й.
        final worse = _countback(lows[0], lows[1], n) < 0 ? lows[0] : lows[1];
        worse.place = place;
      } else {
        _startShootOff(lows, forGold: false, place: place);
        return;
      }
      _elimInCp++;
      if (_elimInCp >= k) {
        _checkpoint++;
        _elimInCp = 0;
      }
    }
  }

  /// Сравнение по счёту ([FinalFormat.countbackBlocks]): >0 — [a] лучше.
  int _countback(FinalCompetitor a, FinalCompetitor b, int n) {
    var end = n;
    for (final size in format.countbackBlocks) {
      final sa = a.shots.sublist(end - size, end).fold<double>(0, (x, y) => x + y);
      final sb = b.shots.sublist(end - size, end).fold<double>(0, (x, y) => x + y);
      final r = ((sa - sb) * 10).round();
      if (r != 0) return r;
      end -= size;
    }
    for (var i = end - 1; i >= 0; i--) {
      final r = ((a.shots[i] - b.shots[i]) * 10).round();
      if (r != 0) return r;
    }
    return 0;
  }

  void _startShootOff(List<FinalCompetitor> tied, {required bool forGold, required int place}) {
    phase = FinalPhase.shootOff;
    _tied = [...tied];
    _soRound = 0;
    _soForGold = forGold;
    _soPlace = place;
    for (final c in tied) {
      c.shootoff.clear();
    }
  }

  void _resolveShootOff() {
    final scores = {for (final c in _tied) c: c.shootoff[_soRound]};
    final target = _soForGold
        ? scores.values.reduce(math.max) // за золото — лучший
        : scores.values.reduce(math.min); // за выбывание — худший
    final stay = [for (final e in scores.entries) if (e.value == target) e.key];
    if (stay.length > 1) {
      _tied = stay; // ничья осталась — ещё круг
      _soRound++;
      return;
    }
    final decided = stay.first;
    if (_soForGold) {
      final other = active.firstWhere((c) => c != decided);
      decided.place = 1;
      other.place = 2;
      phase = FinalPhase.finished;
    } else {
      decided.place = _soPlace;
      phase = FinalPhase.match;
      _elimInCp++;
      if (_elimInCp >= format.eliminationsAt(_checkpoint)) {
        _checkpoint++;
        _elimInCp = 0;
      }
    }
    if (_soForGold) _checkpoint++;
    _tied = [];
    if (phase == FinalPhase.match) _advance();
  }

  /// Таблица: активные сверху по сумме, затем выбывшие от лучшего места к
  /// худшему; после финала все с местами — по месту.
  List<FinalCompetitor> get standings {
    final act = active..sort((a, b) => b.total.compareTo(a.total));
    final out = [for (final c in competitors) if (!c.active) c]
      ..sort((a, b) => a.place!.compareTo(b.place!));
    return [...act, ...out];
  }
}
