import '../models/exercise.dart';
import '../widgets/stance_icon.dart';

/// План изготовок упражнения по сериям.
///
/// Зачем (запрос владельца 26.11): в тренировке нужен индикатор изготовки, как
/// на плитках упражнений, а ИИ должен понимать, в каком положении идёт серия.
/// Единый источник — этот класс: и значок в тренировке, и подсказка при выборе
/// мишени, и описание для ИИ берут данные отсюда.
class StancePlan {
  /// Изготовка для каждой серии (индекс = номер серии − 1).
  final List<StanceKind> bySeries;
  final bool threePositions;
  final WeaponKind weapon;

  const StancePlan({
    required this.bySeries,
    required this.threePositions,
    required this.weapon,
  });

  static String label(StanceKind s) => switch (s) {
        StanceKind.prone => 'Лёжа',
        StanceKind.kneeling => 'С колена',
        StanceKind.standing => 'Стоя',
        StanceKind.allThree => 'Три положения',
      };

  /// Сколько серий у упражнения: по описанию серий, иначе по числу выстрелов.
  static int seriesCount(Exercise ex) {
    if (ex.series.isNotEmpty) return ex.series.length;
    if (ex.seriesSize > 0 && ex.totalShots > 0) {
      return (ex.totalShots / ex.seriesSize).ceil();
    }
    return 1;
  }

  static bool _isThreePositions(Exercise ex) {
    final name = '${ex.name} ${ex.shownName}'.toLowerCase();
    if (name.contains('3 полож') ||
        name.contains('три полож') ||
        name.contains('3п') ||
        RegExp(r'3\s*[×x]').hasMatch(name)) {
      return true;
    }
    var prone = false, kneeling = false, standing = false;
    for (final spec in ex.series) {
      final s = spec.name.toLowerCase();
      if (s.contains('лёж') || s.contains('леж')) prone = true;
      if (s.contains('колен')) kneeling = true;
      if (s.contains('стоя') || s.contains('стойк')) standing = true;
    }
    return prone && kneeling && standing;
  }

  static StanceKind? _fromText(String s) {
    if (s.contains('лёж') || s.contains('леж')) return StanceKind.prone;
    if (s.contains('колен')) return StanceKind.kneeling;
    if (s.contains('стоя') || s.contains('стойк')) return StanceKind.standing;
    return null;
  }

  static StanceKind _singleStance(Exercise ex) {
    final name = '${ex.name} ${ex.shownName}'.toLowerCase();
    final fromName = _fromText(name);
    if (fromName != null) return fromName;
    for (final spec in ex.series) {
      final fromSeries = _fromText(spec.name.toLowerCase());
      if (fromSeries != null) return fromSeries;
    }
    return StanceKind.standing;
  }

  factory StancePlan.forExercise(Exercise ex) {
    final weapon = ex.targetFaceCode.toLowerCase().startsWith('pistol')
        ? WeaponKind.pistol
        : WeaponKind.rifle;
    final n = seriesCount(ex);
    if (_isThreePositions(ex)) {
      // Порядок ISSF для 50 м, 3 положения: с колена → лёжа → стоя.
      const order = [StanceKind.kneeling, StanceKind.prone, StanceKind.standing];
      final per = (n / 3).ceil();
      final list = <StanceKind>[];
      for (var i = 0; i < n; i++) {
        list.add(order[(i ~/ per).clamp(0, 2)]);
      }
      return StancePlan(bySeries: list, threePositions: true, weapon: weapon);
    }
    final one = _singleStance(ex);
    return StancePlan(
      bySeries: List.filled(n, one),
      threePositions: false,
      weapon: weapon,
    );
  }

  /// Изготовка серии [seriesNo] (1-based). Для пристрелки — первая.
  StanceKind stanceFor(int seriesNo) {
    if (bySeries.isEmpty) return StanceKind.standing;
    final i = (seriesNo - 1).clamp(0, bySeries.length - 1);
    return bySeries[i];
  }

  /// Есть ли смысл показывать индикатор: для трёх положений — всегда, для
  /// остальных — тоже (владелец просил индикатор в самой тренировке).
  String get orderHint {
    if (!threePositions) return label(bySeries.isEmpty ? StanceKind.standing : bySeries.first);
    final seen = <StanceKind>[];
    for (final s in bySeries) {
      if (!seen.contains(s)) seen.add(s);
    }
    return seen.map(label).join(' → ');
  }

  /// Подсказка под выбором мишени в редакторе упражнения.
  static String hintForFace(String faceCode) {
    final code = faceCode.toLowerCase();
    if (code == 'rifle_50m') {
      return 'Малокалиберная винтовка 50 м. Лёжа — одна изготовка. '
          'В упражнении «3 положения» порядок: с колена → лёжа → стоя.';
    }
    if (code == 'rifle_10m') return 'Пневматическая винтовка 10 м — стоя.';
    if (code.startsWith('pistol')) return 'Пистолет — стоя, с одной руки.';
    return '';
  }
}
