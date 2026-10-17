import 'package:flutter_test/flutter_test.dart';
import 'package:shooting_app/services/local_db_service.dart';
import 'package:shooting_app/services/supabase_auth_service.dart';
import 'package:shooting_app/tasks/task_models.dart';
import 'package:shooting_app/tasks/task_service.dart';

class _Rec extends SupabaseAuthService {
  _Rec(super.db);
  final calls = <(String, String, Object?)>[];
  @override
  Future<dynamic> rest(String method, String path, {Object? body}) async {
    calls.add((method, path, body));
    return const [];
  }
}

void main() {
  test('задание себе: задание, этапы и шаги пишутся в свою базу со связями по id', () async {
    final db = LocalDbService();
    await db.open(overridePath: ':memory:');
    final auth = _Rec(db);
    final plan = TaskPlan(
      title: 'Проба',
      coachText: 'текст',
      stages: [
        TaskStage(steps: [TaskStep(title: 'шаг 1'), TaskStep(title: 'шаг 2')]),
      ],
    );
    final id = await AthleteTaskService(auth).create(plan);
    final paths = auth.calls.map((c) => c.$2).toList();
    expect(paths, ['tasks', 'task_stages', 'task_steps']);
    final task = auth.calls[0].$3 as Map;
    expect(task['id'], id);
    expect(task['title'], 'Проба');
    final stage = (auth.calls[1].$3 as List).single as Map;
    expect(stage['task_id'], id);
    final steps = auth.calls[2].$3 as List;
    expect(steps.length, 2);
    expect((steps.first as Map)['stage_id'], stage['id']);
    expect((steps.last as Map)['position'], 1);
  });
}
