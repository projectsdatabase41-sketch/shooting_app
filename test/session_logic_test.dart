import 'package:flutter_test/flutter_test.dart';
import 'package:shooting_app/logic/session_logic.dart';
import 'package:shooting_app/models/exercise.dart';
import 'package:shooting_app/models/target_face.dart';
import 'package:shooting_app/models/training_session.dart';

void main() {
  const exercise = Exercise(
    id: 'ex1',
    name: 'Test',
    targetFaceCode: 'rifle_10m',
    totalShots: 60,
    seriesSize: 10,
  );
  const face = TargetFace.rifle10m;

  TrainingSession newSession() => const TrainingSession(id: 's1', exerciseId: 'ex1', targetFaceCode: 'rifle_10m');

  group('B.1 — конечный автомат', () {
    test('notStarted --start()--> running', () {
      final s = SessionLogic.start(newSession(), DateTime(2026, 1, 1, 10, 0));
      expect(s.status, SessionStatus.running);
      expect(s.startedAt, DateTime(2026, 1, 1, 10, 0));
    });

    test('pause() допустим только из running', () {
      final notStarted = newSession();
      final unchanged = SessionLogic.pause(notStarted, DateTime.now());
      expect(unchanged.status, SessionStatus.notStarted); // no-op, не exception

      final running = SessionLogic.start(notStarted, DateTime(2026, 1, 1));
      final paused = SessionLogic.pause(running, DateTime(2026, 1, 1, 0, 1));
      expect(paused.status, SessionStatus.paused);
      expect(paused.pauseIntervals.length, 1);
    });

    test('resume() допустим только из paused', () {
      var s = SessionLogic.start(newSession(), DateTime(2026, 1, 1));
      s = SessionLogic.pause(s, DateTime(2026, 1, 1, 0, 1));
      s = SessionLogic.resume(s, DateTime(2026, 1, 1, 0, 2));
      expect(s.status, SessionStatus.running);
      expect(s.pauseIntervals.last.resumedAt, DateTime(2026, 1, 1, 0, 2));
    });

    test('finish() допустим из running и из paused, закрывает открытую паузу', () {
      var s = SessionLogic.start(newSession(), DateTime(2026, 1, 1));
      s = SessionLogic.pause(s, DateTime(2026, 1, 1, 0, 1));
      s = SessionLogic.finish(s, DateTime(2026, 1, 1, 0, 5));
      expect(s.status, SessionStatus.finished);
      expect(s.pauseIntervals.last.resumedAt, DateTime(2026, 1, 1, 0, 5));
      expect(s.finishedAt, DateTime(2026, 1, 1, 0, 5));
    });

    test('finish() безвозвратно очищает корзину', () {
      var s = SessionLogic.addShot(newSession(), exercise, face, 0, 0, DateTime(2026, 1, 1), idGenerator: () => 'sh1');
      s = SessionLogic.deleteShot(s, 'sh1');
      expect(s.trash.length, 1);
      s = SessionLogic.finish(s, DateTime(2026, 1, 1, 0, 10));
      expect(s.trash, isEmpty);
    });

    test('finished — терминальное состояние, addShot запрещён', () {
      var s = SessionLogic.start(newSession(), DateTime(2026, 1, 1));
      s = SessionLogic.finish(s, DateTime(2026, 1, 1, 0, 1));
      final unchanged = SessionLogic.addShot(s, exercise, face, 1, 1, DateTime(2026, 1, 1, 0, 2));
      expect(unchanged.shots, isEmpty);
      expect(unchanged.status, SessionStatus.finished);
    });

    test('addShot() в paused — молча игнорируется, без exception', () {
      var s = SessionLogic.start(newSession(), DateTime(2026, 1, 1));
      s = SessionLogic.pause(s, DateTime(2026, 1, 1, 0, 1));
      expect(() => SessionLogic.addShot(s, exercise, face, 0, 0, DateTime(2026, 1, 1, 0, 2)), returnsNormally);
      final result = SessionLogic.addShot(s, exercise, face, 0, 0, DateTime(2026, 1, 1, 0, 2));
      expect(result.shots, isEmpty);
    });

    test('addShot() в notStarted — неявный старт, затем добавление, sinceLastShot=0', () {
      final now = DateTime(2026, 1, 1, 12, 0, 0);
      final s = SessionLogic.addShot(newSession(), exercise, face, 0, 0, now, idGenerator: () => 'sh1');
      expect(s.status, SessionStatus.running);
      expect(s.startedAt, now);
      expect(s.shots.length, 1);
      expect(SessionLogic.sinceLastShot(s, now), Duration.zero);
    });
  });

  group('B.2/B.3 — таймеры', () {
    test('пауза вычитается из elapsed: 60с работы, 30с пауза, 60с работы -> ~120с', () {
      final t0 = DateTime(2026, 1, 1, 0, 0, 0);
      var s = SessionLogic.start(newSession(), t0);
      s = SessionLogic.pause(s, t0.add(const Duration(seconds: 60)));
      s = SessionLogic.resume(s, t0.add(const Duration(seconds: 90)));
      final now = t0.add(const Duration(seconds: 150));
      expect(SessionLogic.elapsed(s, now), const Duration(seconds: 120));
    });

    test('sinceLastShot не тикает после finished', () {
      final t0 = DateTime(2026, 1, 1, 0, 0, 0);
      var s = SessionLogic.addShot(newSession(), exercise, face, 0, 0, t0, idGenerator: () => 'sh1');
      s = SessionLogic.finish(s, t0.add(const Duration(seconds: 10)));
      final laterCheck = SessionLogic.sinceLastShot(s, t0.add(const Duration(seconds: 999)));
      expect(laterCheck, const Duration(seconds: 10));
    });
  });

  group('B.5 — корзина', () {
    test('восстановление: новый номер = shots.length+1 на момент восстановления, не старый номер', () {
      final t0 = DateTime(2026, 1, 1);
      var s = newSession();
      s = SessionLogic.addShot(s, exercise, face, 0, 0, t0, idGenerator: () => 'a');
      s = SessionLogic.addShot(s, exercise, face, 1, 1, t0, idGenerator: () => 'b');
      s = SessionLogic.addShot(s, exercise, face, 2, 2, t0, idGenerator: () => 'c');
      // удаляем выстрел №2 (id 'b') — deleteShot НЕ перенумеровывает
      // оставшиеся выстрелы, у 'c' shotNumber остаётся 3.
      s = SessionLogic.deleteShot(s, 'b');
      expect(s.shots.map((e) => e.shotNumber), [1, 3]);
      s = SessionLogic.restoreShot(s, 'b', exercise);
      final restored = s.shots.firstWhere((e) => e.id == 'b');
      expect(restored.shotNumber, s.shots.length); // = shots.length на момент восстановления (3)
      expect(restored.shotNumber, 3);
    });

    test('clearTrash — необратимо', () {
      var s = SessionLogic.addShot(newSession(), exercise, face, 0, 0, DateTime(2026, 1, 1), idGenerator: () => 'a');
      s = SessionLogic.deleteShot(s, 'a');
      expect(s.trash.length, 1);
      s = SessionLogic.clearTrash(s);
      expect(s.trash, isEmpty);
    });
  });

  group('B.6 — тренировка-призрак', () {
    test('пустая тренировка (даже если "Начать" нажата) — isGhost=true', () {
      final started = SessionLogic.start(newSession(), DateTime(2026, 1, 1));
      expect(SessionLogic.isGhost(started), isTrue);
    });

    test('тренировка с хотя бы одним выстрелом — isGhost=false', () {
      final withShot = SessionLogic.addShot(newSession(), exercise, face, 0, 0, DateTime(2026, 1, 1), idGenerator: () => 'a');
      expect(SessionLogic.isGhost(withShot), isFalse);
    });
  });
}
