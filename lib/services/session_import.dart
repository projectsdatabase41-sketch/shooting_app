import 'dart:convert';
import 'dart:math' as math;

import 'package:uuid/uuid.dart';

import '../logic/scoring.dart';
import '../models/exercise.dart';
import '../models/shot.dart';
import '../models/target_face.dart';
import '../models/training_session.dart';
import '../state/app_data_store.dart';

/// Импорт готовых тренировок из внешнего файла.
///
/// Зачем отдельный формат, а не разбор PDF прямо в приложении: отчёты
/// SCATT — это PDF с CID-шрифтами (Identity-H) и векторной графикой,
/// где координаты пробоин лежат не текстом, а окружностями на холсте.
/// Полноценный разбор такого файла — это распаковка потоков, разбор
/// таблиц xref, отслеживание матриц преобразования и разбор CMap для
/// текста; в приложении это была бы тысяча строк, живущих ради одного
/// прибора. Поэтому граница проведена здесь: снаружи файл приводится к
/// простому JSON, а приложение умеет только его — коротко, проверяемо
/// и одинаково для любого источника.
///
/// Импорт ВСЕГДА целиком или никак: половина тренировки в базе хуже,
/// чем её отсутствие.
class SessionImport {
  SessionImport._();

  static const String formatId = 'shooting_app.import';
  static const int supportedVersion = 1;

  /// Разбирает файл и проверяет его. Бросает [ImportException] с
  /// человеческим текстом — он показывается пользователю как есть.
  static ImportBundle parse(String raw) {
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (e) {
      throw const ImportException('Это не JSON-файл');
    }
    if (decoded is! Map) {
      throw const ImportException('Ожидался объект с полем "sessions"');
    }

    if (decoded['format'] != formatId) {
      throw ImportException(
        'Чужой формат файла: "${decoded['format']}". Нужен "$formatId".',
      );
    }
    final version = decoded['version'];
    if (version is! int || version > supportedVersion) {
      throw ImportException(
        'Версия файла $version новее, чем понимает приложение ($supportedVersion). '
        'Обновите приложение.',
      );
    }

    final rawSessions = decoded['sessions'];
    if (rawSessions is! List || rawSessions.isEmpty) {
      throw const ImportException('В файле нет ни одной тренировки');
    }

    final source = '${decoded['source'] ?? 'внешний файл'}';
    final sessions = <ImportedSession>[];
    for (var i = 0; i < rawSessions.length; i++) {
      try {
        sessions.add(_session(rawSessions[i], source));
      } on ImportException catch (e) {
        throw ImportException('Тренировка ${i + 1}: ${e.message}');
      }
    }
    return ImportBundle(source: source, sessions: sessions);
  }

  static ImportedSession _session(Object? raw, String source) {
    if (raw is! Map) throw const ImportException('ожидался объект');

    final ex = raw['exercise'];
    if (ex is! Map) throw const ImportException('нет блока "exercise"');
    final faceCode = '${ex['target_face_code']}';
    // Мишень должна быть известна приложению: иначе не посчитать ни
    // очки, ни геометрию, и тренировка будет мусором в списке.
    if (!TargetFace.all.any((f) => f.code == faceCode)) {
      throw ImportException('неизвестная мишень "$faceCode"');
    }

    final rawShots = raw['shots'];
    if (rawShots is! List || rawShots.isEmpty) {
      throw const ImportException('нет выстрелов');
    }

    final startedAt = _dateOrNull(raw['started_at']);
    if (startedAt == null) {
      throw const ImportException('не указана дата начала');
    }

    const uuid = Uuid();
    final sessionId = uuid.v4();
    final shots = <Shot>[];
    for (var i = 0; i < rawShots.length; i++) {
      final s = rawShots[i];
      if (s is! Map) throw ImportException('выстрел ${i + 1}: ожидался объект');
      final score = _num(s['score'], 'выстрел ${i + 1}: score');
      if (score < 0 || score > 10.9) {
        throw ImportException('выстрел ${i + 1}: результат $score вне шкалы 0…10.9');
      }
      final (x, y, coordsNote) = _coordinates(s, i, faceCode, score);
      shots.add(Shot(
        id: uuid.v4(),
        shotNumber: (s['n'] as num?)?.toInt() ?? (i + 1),
        seriesNo: (s['series'] as num?)?.toInt() ?? 1,
        xMm: x,
        yMm: y,
        score: score,
        time: _dateOrNull(s['time']) ?? startedAt,
        // Результат пришёл готовым и пересчёту по координатам не
        // подлежит. Координаты из отчёта восстановлены с точностью
        // около сотой миллиметра, и у выстрелов ровно на границе
        // десятой доли пересчёт дал бы 10.5 там, где прибор написал
        // 10.4. Прибор здесь — источник истины.
        isManuallyEdited: true,
        // По умолчанию выстрел зачётный; источник может пометить
        // пристрелку явно.
        counts: s['counts'] != false,
        extra: coordsNote == null
            ? _extra(s['extra'])
            : {...?_extra(s['extra']), 'координаты': coordsNote},
      ));
    }

    return ImportedSession(
      exerciseName: '${ex['name'] ?? ex['code'] ?? 'Без названия'}',
      targetFaceCode: faceCode,
      totalShots: (ex['total_shots'] as num?)?.toInt() ?? shots.length,
      seriesSize: (ex['series_size'] as num?)?.toInt() ?? shots.length,
      session: TrainingSession(
        id: sessionId,
        exerciseId: '', // подставится при применении
        targetFaceCode: faceCode,
        status: SessionStatus.finished,
        startedAt: startedAt,
        finishedAt: _dateOrNull(raw['finished_at']) ?? startedAt,
        shots: shots,
        extra: {
          ...?_extra(raw['extra']),
          'импортировано_из': source,
        },
      ),
    );
  }

  /// Координаты выстрела. Есть `x_mm` и `y_mm` — берём как есть. Нет ни
  /// одного — восстанавливаем из результата и направления: радиус даёт
  /// проверенная `radiusForScore` (модели, читающие фото/PDF, ошибаются в
  /// арифметике и в знаке оси Y — считать за них должно приложение), а от
  /// источника нужно только НАПРАВЛЕНИЕ (`angle_deg`, `clock` или
  /// `direction`). Направления нет вовсе — радиус верный, угол
  /// раскладывается по золотому углу (выстрелы не слипаются в одну
  /// точку, а среднее не смещается в одну сторону) и это помечается в
  /// `extra`, чтобы не выдавать выдуманное положение за измеренное.
  static (double, double, String?) _coordinates(Map s, int i, String faceCode, double score) {
    final hasX = s.containsKey('x_mm') && s['x_mm'] != null;
    final hasY = s.containsKey('y_mm') && s['y_mm'] != null;
    if (hasX && hasY) {
      return (_num(s['x_mm'], 'выстрел ${i + 1}: x_mm'), _num(s['y_mm'], 'выстрел ${i + 1}: y_mm'), null);
    }
    if (hasX != hasY) {
      throw ImportException('выстрел ${i + 1}: нужны оба x_mm и y_mm — либо ни одного (тогда направление и результат)');
    }
    final face = TargetFace.all.firstWhere((f) => f.code == faceCode);
    final r = _radiusFromScore(score, face);
    final angle = _angleDeg(s);
    final deg = angle ?? (i * 137.50776) % 360;
    final rad = deg * math.pi / 180;
    return (
      r * math.sin(rad),
      r * math.cos(rad),
      angle == null
          ? 'радиус из результата, направление неизвестно (условное)'
          : 'восстановлены из результата и направления',
    );
  }

  /// Расстояние от центра по результату `ring.decimal`. Результат ниже
  /// единицы — за внешним кольцом: `radiusForScore` для него вернул бы 0.
  static double _radiusFromScore(double score, TargetFace face) {
    final tenths = (score * 10).round();
    final ring = tenths ~/ 10;
    if (ring < 1) return face.ringRadiiMm.last + face.caliberRadiusMm + 1;
    return radiusForScore(ring, tenths % 10, face);
  }

  static const Map<String, double> _compass = {
    '↑': 0, 'N': 0, 'С': 0, '↗': 45, 'NE': 45, 'СВ': 45, '→': 90, 'E': 90, 'В': 90,
    '↘': 135, 'SE': 135, 'ЮВ': 135, '↓': 180, 'S': 180, 'Ю': 180, '↙': 225, 'SW': 225,
    'ЮЗ': 225, '←': 270, 'W': 270, 'З': 270, '↖': 315, 'NW': 315, 'СЗ': 315,
  };

  /// Направление в градусах: 0 — вверх, по часовой стрелке (как на
  /// циферблате). Источники: `angle_deg`, `clock` (`3`, `3.5`, `"3:25"`),
  /// `direction` (стрелка ↑↗→↘↓↙←↖, N/NE/E…, С/СВ/В…, «центр»). `null` —
  /// направления в выстреле нет.
  static double? _angleDeg(Map s) {
    final a = s['angle_deg'];
    if (a is num) return a.toDouble() % 360;

    final c = s['clock'];
    if (c is num) return (c.toDouble() % 12) * 30;
    if (c is String) {
      final m = RegExp(r'^\s*(\d{1,2})(?::(\d{1,2}))?\s*$').firstMatch(c);
      if (m != null) {
        final h = int.parse(m.group(1)!) % 12;
        return h * 30 + int.parse(m.group(2) ?? '0') * 0.5;
      }
    }

    final d = s['direction'];
    if (d is String) {
      final key = d.trim().toUpperCase();
      if (key == 'ЦЕНТР' || key == 'CENTER' || key == '●' || key == 'О') return 0;
      return _compass[key];
    }
    return null;
  }

  static Map<String, dynamic>? _extra(Object? v) {
    if (v is Map) return v.map((k, e) => MapEntry('$k', e));
    return null;
  }

  static double _num(Object? v, String where) {
    if (v is num) return v.toDouble();
    throw ImportException('$where — не число');
  }

  static DateTime? _dateOrNull(Object? v) {
    if (v is! String) return null;
    return DateTime.tryParse(v);
  }

  /// Записывает разобранное в базу.
  ///
  /// Упражнения не плодятся: если уже есть упражнение с тем же кодом,
  /// мишенью и размером серии, тренировка привязывается к нему.
  /// Иначе история распадётся на десяток одинаковых «ВП-60», и срез
  /// «по упражнению» перестанет что-либо значить.
  static int apply(AppDataStore store, ImportBundle bundle) {
    var added = 0;
    for (final s in bundle.sessions) {
      final exercise = _findOrCreateExercise(store, s);
      store.upsertSession(s.session.copyWith(exerciseId: exercise.id));
      added++;
    }
    return added;
  }

  static Exercise _findOrCreateExercise(AppDataStore store, ImportedSession s) {
    for (final e in store.exercises) {
      // Совпадение ищем по названию, мишени и размеру серии: кода у
      // упражнения больше нет.
      if (e.name == s.exerciseName &&
          e.targetFaceCode == s.targetFaceCode &&
          e.seriesSize == s.seriesSize) {
        return e;
      }
    }
    return store.createExercise(
      name: s.exerciseName,
      targetFaceCode: s.targetFaceCode,
      totalShots: s.totalShots,
      seriesSize: s.seriesSize,
    );
  }
}

/// Разобранный файл целиком.
class ImportBundle {
  final String source;
  final List<ImportedSession> sessions;

  const ImportBundle({required this.source, required this.sessions});

  int get shotCount => sessions.fold(0, (a, s) => a + s.session.shots.length);
}

/// Одна тренировка из файла вместе с описанием своего упражнения.
class ImportedSession {
  final String exerciseName;
  final String targetFaceCode;
  final int totalShots;
  final int seriesSize;
  final TrainingSession session;

  const ImportedSession({
    required this.exerciseName,
    required this.targetFaceCode,
    required this.totalShots,
    required this.seriesSize,
    required this.session,
  });

  String get label => exerciseName;
}

class ImportException implements Exception {
  final String message;
  const ImportException(this.message);
  @override
  String toString() => message;
}
