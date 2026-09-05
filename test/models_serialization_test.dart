import 'package:flutter_test/flutter_test.dart';
import 'package:shooting_app/models/comment.dart';
import 'package:shooting_app/models/exercise.dart';
import 'package:shooting_app/models/share_grant.dart';
import 'package:shooting_app/models/shot.dart';
import 'package:shooting_app/models/target_face.dart';
import 'package:shooting_app/models/training_session.dart';

void main() {
  group('Сериализация моделей туда-обратно (задача 1.1 dev-task-spec.md)', () {
    test('Shot', () {
      final shot = Shot(
        id: 'sh1',
        shotNumber: 3,
        seriesNo: 1,
        xMm: 1.23,
        yMm: -4.56,
        score: 9.4,
        time: DateTime(2026, 9, 1, 12, 30),
        isFavorite: true,
        isManuallyEdited: true,
      );
      final restored = Shot.fromJson(shot.toJson());
      expect(restored.id, shot.id);
      expect(restored.shotNumber, shot.shotNumber);
      expect(restored.seriesNo, shot.seriesNo);
      expect(restored.xMm, shot.xMm);
      expect(restored.yMm, shot.yMm);
      expect(restored.score, shot.score);
      expect(restored.time, shot.time);
      expect(restored.isFavorite, shot.isFavorite);
      expect(restored.isManuallyEdited, shot.isManuallyEdited);
    });

    test('Exercise', () {
      const ex = Exercise(
        id: 'ex1',
        name: 'ВП-60',
        targetFaceCode: 'rifle_10m',
        totalShots: 60,
        seriesSize: 10,
        gender: ExerciseGender.female,
      );
      final restored = Exercise.fromJson(ex.toJson());
      expect(restored.id, ex.id);
      expect(restored.name, ex.name);
      expect(restored.targetFaceCode, ex.targetFaceCode);
      expect(restored.totalShots, ex.totalShots);
      expect(restored.seriesSize, ex.seriesSize);
      expect(restored.gender, ex.gender);
      expect(restored.deletedAt, isNull);
      expect(restored.isDeleted, isFalse);
      expect(ex.label, 'ВП-60');
    });

    test('Exercise — мягкое удаление переживает round-trip', () {
      final ex = Exercise(
        id: 'ex2',
        name: 'ВП-40',
        targetFaceCode: 'rifle_10m',
        totalShots: 40,
        seriesSize: 10,
        deletedAt: DateTime(2026, 9, 4, 12, 30),
      );
      final restored = Exercise.fromJson(ex.toJson());
      expect(restored.deletedAt, ex.deletedAt);
      expect(restored.isDeleted, isTrue);
      // Подпись с пометкой — именно она уходит в историю и ассистенту,
      // чтобы прошлые тренировки не остались безымянными.
      expect(restored.label, 'ВП-40 (удалено)');
    });

    test('TargetFace — все 4 мишени round-trip', () {
      for (final face in TargetFace.all) {
        final restored = TargetFace.fromJson(face.toJson());
        expect(restored.code, face.code);
        expect(restored.caliberMm, face.caliberMm);
        expect(restored.bullseyeDiameterMm, face.bullseyeDiameterMm);
        expect(restored.blankSizeMm, face.blankSizeMm);
        expect(restored.ringDiametersMm, face.ringDiametersMm);
        // Внутренняя десятка — nullable (у № 8 её нет), round-trip
        // должен сохранять и null, и значение.
        expect(restored.innerTenDiameterMm, face.innerTenDiameterMm);
        expect(restored.gauging, face.gauging, reason: 'метод измерения');
      }
    });

    test('TargetFace — оружие и боеприпас для контекста ИИ выводятся верно', () {
      expect(TargetFace.rifle10m.weaponRu, 'винтовка');
      expect(TargetFace.rifle50m.weaponRu, 'винтовка');
      expect(TargetFace.pistol10m.weaponRu, 'пистолет');
      expect(TargetFace.pistol25m.weaponRu, 'пистолет');

      expect(TargetFace.rifle10m.ammoRu, contains('пневматическое'));
      expect(TargetFace.pistol10m.ammoRu, contains('пневматическое'));
      expect(TargetFace.rifle50m.ammoRu, contains('.22 LR'));
      expect(TargetFace.pistol25m.ammoRu, contains('.22 LR'));
    });

    test('Comment — все три уровня', () {
      final shotComment = Comment(
        id: 'c1',
        sessionId: 's1',
        level: CommentLevel.shot,
        shotId: 'sh1',
        authorRole: AuthorRole.coach,
        text: 'Хорошо',
        createdAt: DateTime(2026, 9, 1),
      );
      expect(Comment.fromJson(shotComment.toJson()).shotId, 'sh1');

      final seriesComment = Comment(
        id: 'c2',
        sessionId: 's1',
        level: CommentLevel.series,
        seriesNo: 2,
        authorRole: AuthorRole.athlete,
        text: 'Серия ок',
        createdAt: DateTime(2026, 9, 1),
      );
      expect(Comment.fromJson(seriesComment.toJson()).seriesNo, 2);

      final sessionComment = Comment(
        id: 'c3',
        sessionId: 's1',
        level: CommentLevel.session,
        authorRole: AuthorRole.athlete,
        text: 'Тренировка ок',
        createdAt: DateTime(2026, 9, 1),
      );
      final restored = Comment.fromJson(sessionComment.toJson());
      expect(restored.shotId, isNull);
      expect(restored.seriesNo, isNull);

      // 'coach' — отдельный от 'session' уровень (чат со тренером),
      // та же форма полей (ни shotId, ни seriesNo).
      final coachComment = Comment(
        id: 'c4',
        sessionId: 's1',
        level: CommentLevel.coach,
        authorRole: AuthorRole.athlete,
        text: 'Вопрос тренеру',
        createdAt: DateTime(2026, 9, 1),
      );
      final restoredCoach = Comment.fromJson(coachComment.toJson());
      expect(restoredCoach.level, CommentLevel.coach);
      expect(restoredCoach.shotId, isNull);
      expect(restoredCoach.seriesNo, isNull);
    });

    test('Comment — assert ловит некорректную комбинацию уровня/полей', () {
      expect(
        () => Comment(
          id: 'bad',
          sessionId: 's1',
          level: CommentLevel.shot,
          shotId: null, // должно быть заполнено при level=shot
          authorRole: AuthorRole.athlete,
          text: 'x',
          createdAt: DateTime(2026, 9, 1),
        ),
        throwsA(isA<AssertionError>()),
      );
    });

    test('ShareGrant', () {
      final grant = ShareGrant(
        id: 'g1',
        tokenHash: 'abcd',
        athleteLabel: 'Иванов',
        createdAt: DateTime(2026, 9, 1),
        revokedAt: DateTime(2026, 9, 2),
      );
      final restored = ShareGrant.fromJson(grant.toJson());
      expect(restored.isActive, isFalse);
      expect(restored.tokenHash, 'abcd');
    });

    test('TrainingSession — со вложенными выстрелами и корзиной', () {
      final session = TrainingSession(
        id: 'sess1',
        exerciseId: 'ex1',
        targetFaceCode: 'rifle_10m',
        status: SessionStatus.paused,
        startedAt: DateTime(2026, 9, 1, 10, 0),
        pauseIntervals: [PauseInterval(pausedAt: DateTime(2026, 9, 1, 10, 5))],
        shots: [
          Shot(id: 'sh1', shotNumber: 1, seriesNo: 1, xMm: 0, yMm: 0, score: 10.9, time: DateTime(2026, 9, 1, 10, 1)),
        ],
        trash: [
          Shot(id: 'sh2', shotNumber: 2, seriesNo: 1, xMm: 5, yMm: 5, score: 8.0, time: DateTime(2026, 9, 1, 10, 2)),
        ],
      );
      final restored = TrainingSession.fromJson(session.toJson());
      expect(restored.status, SessionStatus.paused);
      expect(restored.shots.length, 1);
      expect(restored.trash.length, 1);
      expect(restored.pauseIntervals.length, 1);
      expect(restored.totalScore, 10.9);
    });
  });
}
