import '../models/exercise.dart';

/// Режим ступени задания (sql/tasks.sql, task_stages.mode).
enum StageMode {
  /// Один этап — сразу показать, что делать.
  single('single'),

  /// Несколько этапов одной страницей (разделены только в записи).
  together('together'),

  /// Все этапы, порядок выбирает спортсмен.
  anyOrder('any_order'),

  /// Один этап на выбор спортсмена.
  pickOne('pick_one');

  const StageMode(this.db);
  final String db;

  static StageMode fromDb(String? v) => values.firstWhere((m) => m.db == v, orElse: () => single);
}

/// Этап задания. [exercise] — {target_face_code, shots, series_size, position};
/// [sighting] — {required, max_shots, time_sec}; [noteMode] — где просить
/// отметку: shot | series | step | none.
class TaskStep {
  final String? id;
  String title;
  String instructions;
  Map<String, dynamic>? exercise;
  int? timeLimitSec;
  Map<String, dynamic>? sighting;
  String noteMode;
  bool keepStats;

  TaskStep({
    this.id,
    required this.title,
    this.instructions = '',
    this.exercise,
    this.timeLimitSec,
    this.sighting,
    this.noteMode = 'step',
    this.keepStats = false,
  });

  bool get isShooting => (exercise?['shots'] as num?) != null && (exercise?['shots'] as num) > 0;
  int get plannedShots => (exercise?['shots'] as num?)?.toInt() ?? 0;
  String get faceCode => '${exercise?['target_face_code'] ?? 'rifle_10m'}';

  /// Упражнение-однодневка для мишени этапа (в список упражнений не попадает).
  Exercise toExercise() => Exercise(
        id: 'task-step-${id ?? title}',
        name: title,
        targetFaceCode: faceCode,
        totalShots: plannedShots > 0 ? plannedShots : 10,
        seriesSize: (exercise?['series_size'] as num?)?.toInt() ?? 10,
      );

  factory TaskStep.fromJson(Map<String, dynamic> j) => TaskStep(
        id: j['id'] as String?,
        title: '${j['title'] ?? ''}',
        instructions: '${j['instructions'] ?? ''}',
        exercise: (j['exercise'] as Map?)?.cast<String, dynamic>(),
        timeLimitSec: (j['time_limit_sec'] as num?)?.toInt(),
        sighting: (j['sighting'] as Map?)?.cast<String, dynamic>(),
        noteMode: '${j['note_mode'] ?? 'step'}',
        keepStats: j['keep_stats'] == true,
      );

  Map<String, dynamic> toJson() => {
        'title': title,
        'instructions': instructions,
        if (exercise != null) 'exercise': exercise,
        if (timeLimitSec != null) 'time_limit_sec': timeLimitSec,
        if (sighting != null) 'sighting': sighting,
        'note_mode': noteMode,
        'keep_stats': keepStats,
      };
}

class TaskStage {
  final String? id;
  StageMode mode;
  final List<TaskStep> steps;

  TaskStage({this.id, this.mode = StageMode.single, List<TaskStep>? steps}) : steps = steps ?? [];

  factory TaskStage.fromJson(Map<String, dynamic> j) {
    final raw = (j['steps'] ?? j['task_steps'] ?? const []) as List;
    final steps = [for (final s in raw) TaskStep.fromJson((s as Map).cast<String, dynamic>())];
    return TaskStage(id: j['id'] as String?, mode: StageMode.fromDb(j['mode'] as String?), steps: steps);
  }

  Map<String, dynamic> toJson() => {
        'mode': mode.db,
        'steps': [for (final s in steps) s.toJson()]
      };
}

/// Краткие сведения о прохождении (для списков).
class TaskRunInfo {
  final String id;
  final DateTime? startedAt;
  final DateTime? finishedAt;
  final String status;
  const TaskRunInfo({required this.id, this.startedAt, this.finishedAt, required this.status});

  factory TaskRunInfo.fromJson(Map<String, dynamic> j) => TaskRunInfo(
        id: '${j['id']}',
        startedAt: DateTime.tryParse('${j['started_at']}')?.toLocal(),
        finishedAt: DateTime.tryParse('${j['finished_at']}')?.toLocal(),
        status: '${j['status'] ?? 'done'}',
      );
}

/// Задание целиком: план + (при чтении) прохождения.
class TaskPlan {
  final String? id;
  String title;
  String coachText;
  DateTime? dueAt;
  String? repeatRule;
  String? groupKey;
  String status;
  final DateTime? createdAt;
  final List<TaskStage> stages;
  final List<({String question, String answer})> clarifications;
  final List<TaskRunInfo> runs;

  /// Сырой ответ базы по прохождениям (выстрелы, отметки, отчёты) — у тренера.
  final List<Map<String, dynamic>> runsRaw;

  TaskPlan({
    this.id,
    required this.title,
    this.coachText = '',
    this.dueAt,
    this.repeatRule,
    this.groupKey,
    this.status = 'active',
    this.createdAt,
    List<TaskStage>? stages,
    List<({String question, String answer})>? clarifications,
    List<TaskRunInfo>? runs,
    List<Map<String, dynamic>>? runsRaw,
  })  : stages = stages ?? [],
        clarifications = clarifications ?? [],
        runs = runs ?? [],
        runsRaw = runsRaw ?? [];

  bool get removed => status == 'removed';
  bool get done => runs.any((r) => r.status == 'done');
  int get stepCount => stages.fold(0, (a, s) => a + s.steps.length);

  /// Из вложенного ответа PostgREST (tasks?select=*,task_stages(*,task_steps(*)),task_runs(*))
  /// или из элемента coach_get_tasks ({task, stages, runs}).
  factory TaskPlan.fromJson(Map<String, dynamic> j) {
    final t = (j['task'] as Map?)?.cast<String, dynamic>() ?? j;
    final rawStages = (j['stages'] ?? t['task_stages'] ?? const []) as List;
    final stages = [
      for (final s in rawStages) (s as Map).cast<String, dynamic>(),
    ]..sort((a, b) => ((a['position'] as num?) ?? 0).compareTo((b['position'] as num?) ?? 0));
    final rawRuns = [
      for (final r in (j['runs'] ?? t['task_runs'] ?? const []) as List) (r as Map).cast<String, dynamic>()
    ];
    return TaskPlan(
      id: t['id'] as String?,
      title: '${t['title'] ?? ''}',
      coachText: '${t['coach_text'] ?? ''}',
      dueAt: DateTime.tryParse('${t['due_at']}')?.toLocal(),
      repeatRule: t['repeat_rule'] as String?,
      groupKey: t['group_key'] as String?,
      status: '${t['status'] ?? 'active'}',
      createdAt: DateTime.tryParse('${t['created_at']}')?.toLocal(),
      stages: [
        for (final s in stages)
          TaskStage.fromJson({
            ...s,
            'steps': ([...((s['steps'] ?? s['task_steps'] ?? const []) as List)]..sort(
                (a, b) => (((a as Map)['position'] as num?) ?? 0).compareTo(((b as Map)['position'] as num?) ?? 0))),
          }),
      ],
      runs: [for (final r in rawRuns) TaskRunInfo.fromJson(r)],
      runsRaw: rawRuns,
    );
  }

  Map<String, dynamic> toJson() => {
        'title': title,
        'coach_text': coachText,
        if (dueAt != null) 'due_at': dueAt!.toUtc().toIso8601String(),
        if (repeatRule != null) 'repeat_rule': repeatRule,
        if (groupKey != null) 'group_key': groupKey,
        'stages': [for (final s in stages) s.toJson()],
        'clarifications': [
          for (final c in clarifications) {'question': c.question, 'answer': c.answer}
        ],
      };
}
