import '../models/shot.dart';
import '../models/training_session.dart';
import '../i18n/i18n.dart';

/// Сводит сырые RPC-строки `CoachAccessService` (реальная схема Supabase,
/// см. docs/db-schema-actual.md) в те же модели (`TrainingSession`/`Shot`),
/// которыми уже пользуются `AnalyticsPanel` и `AiContext` — так статистика
/// и чат с ИИ тренера переиспользуют весь существующий код вместо того,
/// чтобы заново разбирать графики по сырым картам.
///
/// Своего каталога упражнений у тренера нет — `exerciseId` тут
/// синтетический (=id тренировки), а название берётся прямо из
/// `exercise_name` через [exerciseNameOf].
List<TrainingSession> mapCoachSessions(
  List<Map<String, dynamic>> packages,
  List<Map<String, dynamic>> exerciseRows,
  Map<String, List<Map<String, dynamic>>> shotsByPackageId,
) {
  final childByPackage = {for (final r in exerciseRows) '${r['package_id']}': r};
  final sessions = <TrainingSession>[];
  for (final p in packages) {
    final id = '${p['id']}';
    final child = childByPackage[id];
    if (child == null) continue;
    final faceCode = '${child['discipline'] ?? ''}';
    if (faceCode.isEmpty) continue;
    final sessionStart = DateTime.tryParse('${p['started_at']}');
    final shots = [
      for (final r in shotsByPackageId[id] ?? const <Map<String, dynamic>>[]) shotFromCoachRow(r, sessionStart),
    ]..sort((a, b) => a.shotNumber.compareTo(b.shotNumber));
    sessions.add(TrainingSession(
      id: id,
      exerciseId: id,
      targetFaceCode: faceCode,
      status: SessionStatus.finished,
      startedAt: sessionStart,
      finishedAt: DateTime.tryParse('${p['ended_at']}'),
      shots: shots,
      syncedToCloud: true,
    ));
  }
  return sessions;
}

/// Название упражнения тренировки [s] — по `exercise_name` из строки
/// `exercises`, которую надо было запомнить заранее (тот же принцип, что
/// `store.exerciseFor(s)?.label` у спортсмена, только без каталога).
String Function(TrainingSession) coachExerciseNameOf(List<Map<String, dynamic>> exerciseRows) {
  final nameByPackage = {for (final r in exerciseRows) '${r['package_id']}': '${r['exercise_name'] ?? ''}'};
  return (s) => nameByPackage[s.id]?.isNotEmpty == true ? nameByPackage[s.id]! : tr('Упражнение');
}

Shot shotFromCoachRow(Map<String, dynamic> r, DateTime? sessionStart) {
  // shot_time_ms — смещение от начала тренировки в миллисекундах (та же
  // логика, что и в `SupabaseService._shotFromRow` при обычном pull).
  final offsetMs = (r['shot_time_ms'] as num?)?.toInt();
  final time = (offsetMs != null && sessionStart != null)
      ? sessionStart.add(Duration(milliseconds: offsetMs))
      : DateTime.tryParse('${r['created_at']}') ?? DateTime.now();
  return Shot(
    id: '${r['id']}',
    shotNumber: (r['shot_no'] as num).toInt(),
    seriesNo: (r['series_no'] as num?)?.toInt() ?? 1,
    xMm: (r['x_mm'] as num?)?.toDouble() ?? 0,
    yMm: (r['y_mm'] as num?)?.toDouble() ?? 0,
    score: (r['final_score'] as num).toDouble(),
    time: time,
  );
}
