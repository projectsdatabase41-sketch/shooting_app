import 'package:flutter_test/flutter_test.dart';
import 'package:shooting_app/tasks/task_models.dart';

void main() {
  test('задание: ответ coach_get_tasks и вложенный ответ PostgREST разбираются одинаково', () {
    final stages = [
      {
        'position': 1,
        'mode': 'any_order',
        'steps': [
          {'position': 1, 'title': 'E'},
          {'position': 0, 'title': 'D'},
        ],
      },
      {
        'position': 0,
        'mode': 'together',
        'steps': [
          {'position': 0, 'title': 'A', 'exercise': {'target_face_code': 'rifle_10m', 'shots': 20}, 'note_mode': 'series'},
          {'position': 1, 'title': 'B'},
        ],
      },
    ];
    final coach = TaskPlan.fromJson({
      'task': {'id': 't1', 'title': 'Тест', 'status': 'removed', 'group_key': 'g'},
      'stages': stages,
      'runs': [
        {'id': 'r1', 'status': 'done'},
      ],
    });
    final athlete = TaskPlan.fromJson({
      'id': 't1',
      'title': 'Тест',
      'status': 'removed',
      'task_stages': [
        for (final s in stages) {...s, 'task_steps': s['steps'], 'steps': null},
      ],
      'task_runs': const [],
    });
    for (final p in [coach, athlete]) {
      expect(p.stages.map((s) => s.mode), [StageMode.together, StageMode.anyOrder]);
      expect(p.stages.first.steps.map((s) => s.title), ['A', 'B']);
      expect(p.stages.last.steps.map((s) => s.title), ['D', 'E']);
      expect(p.stages.first.steps.first.plannedShots, 20);
      expect(p.stages.first.steps.first.noteMode, 'series');
      expect(p.removed, isTrue);
      expect(p.stepCount, 4);
    }
    expect(coach.done, isTrue);
    expect(athlete.done, isFalse);
    // Обратно в формат coach_create_task — режимы и этапы на месте.
    final json = coach.toJson();
    expect((json['stages'] as List).first['mode'], 'together');
    expect(((json['stages'] as List).first['steps'] as List).first['exercise'], {'target_face_code': 'rifle_10m', 'shots': 20});
  });
}
