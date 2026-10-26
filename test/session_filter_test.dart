import 'package:flutter_test/flutter_test.dart';
import 'package:shooting_app/logic/session_filter.dart';
import 'package:shooting_app/models/shot.dart';
import 'package:shooting_app/models/training_session.dart';

Shot _shot(int n, double score, double x, double y) =>
    Shot(id: 's$n', shotNumber: n, seriesNo: 1, xMm: x, yMm: y, score: score, time: DateTime(2026, 9, 1));

TrainingSession _session(List<Shot> shots, {DateTime? start, DateTime? end}) => TrainingSession(
      id: 't',
      exerciseId: 'e',
      targetFaceCode: 'rifle_10m',
      shots: shots,
      startedAt: start,
      finishedAt: end,
    );

void main() {
  final good = _session([for (var i = 0; i < 10; i++) _shot(i, 10.2, 1, 1)], start: DateTime(2026, 9, 10, 10), end: DateTime(2026, 9, 10, 10, 40));
  final bad = _session([for (var i = 0; i < 5; i++) _shot(i, 8.0, 6, 6)], start: DateTime(2026, 10, 2, 10), end: DateTime(2026, 10, 2, 10, 10));

  test('результат, число выстрелов, СТП, период, длительность', () {
    expect(SessionFilter(minScore: 100).matches(good, hasNotes: false), isTrue);
    expect(SessionFilter(minScore: 100).matches(bad, hasNotes: false), isFalse);
    expect(SessionFilter(minShots: 8, maxShots: 12).matches(good, hasNotes: false), isTrue);
    expect(SessionFilter(minShots: 8).matches(bad, hasNotes: false), isFalse);
    expect(SessionFilter(maxStpMm: 3).matches(good, hasNotes: false), isTrue); // средняя точка ~1.4 мм
    expect(SessionFilter(maxStpMm: 3).matches(bad, hasNotes: false), isFalse); // ~8.5 мм
    expect(SessionFilter(from: DateTime(2026, 9, 1), to: DateTime(2026, 9, 30)).matches(good, hasNotes: false), isTrue);
    expect(SessionFilter(from: DateTime(2026, 9, 1), to: DateTime(2026, 9, 30)).matches(bad, hasNotes: false), isFalse);
    expect(SessionFilter(minMinutes: 30).matches(good, hasNotes: false), isTrue);
    expect(SessionFilter(minMinutes: 30).matches(bad, hasNotes: false), isFalse);
  });

  test('заметки: только те, где они есть', () {
    expect(SessionFilter(onlyWithNotes: true).matches(good, hasNotes: false), isFalse);
    expect(SessionFilter(onlyWithNotes: true).matches(good, hasNotes: true), isTrue);
    expect(SessionFilter().isEmpty, isTrue);
  });

  test('ответ ИИ: берутся только допустимые поля, мусор и пустое — null', () {
    final f = SessionFilter.fromAiReply('{"minScore": 600, "from": "2026-09-01", "to":"2026-09-30", "notes": true, "x": 1, "maxStp": -5}')!;
    expect(f.minScore, 600);
    expect(f.from, DateTime(2026, 9, 1));
    expect(f.onlyWithNotes, isTrue);
    expect(f.maxStpMm, isNull); // отрицательное отброшено
    expect(SessionFilter.fromAiReply('{}'), isNull);
    expect(SessionFilter.fromAiReply('не json'), isNull);
  });
}
