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
  });

  int get totalShots => seriesShots.fold(0, (a, b) => a + b) + singleShots;

  /// Лимит времени на выстрел с номером [shotIndex] (с нуля): в сериях —
  /// общий лимит серии, дальше — на каждый выстрел.
  int secondsForShot(int shotIndex) {
    var left = shotIndex;
    for (final s in seriesShots) {
      if (left < s) return seriesSeconds;
      left -= s;
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

  static const all = [airRifle10m, airPistol10m];
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
      final lowest = act.map((c) => c.totalAt(n)).reduce(math.min);
      final lows = [for (final c in act) if (c.totalAt(n) == lowest) c];
      final place = format.finalists - _checkpoint;
      if (lows.length == 1) {
        lows.first.place = place;
        _checkpoint++;
      } else {
        _startShootOff(lows, forGold: false, place: place);
        return;
      }
    }
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
    }
    _checkpoint++;
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
