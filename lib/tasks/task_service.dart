import 'dart:convert';

import 'package:http/http.dart' as http;

import '../services/call_service.dart';
import '../services/coach_access_service.dart';
import '../services/supabase_auth_service.dart';
import 'task_models.dart';

/// Задания спортсмена — в его личной базе, он владелец (sql/tasks.sql).
class AthleteTaskService {
  final SupabaseAuthService auth;
  AthleteTaskService(this.auth);

  bool get available => auth.isSignedIn;

  Future<List<TaskPlan>> list() async {
    final rows = (await auth.rest('GET',
            'tasks?select=*,task_stages(*,task_steps(*)),task_runs(id,started_at,finished_at,status)&order=created_at.desc'))
        as List;
    return [for (final r in rows) TaskPlan.fromJson((r as Map).cast<String, dynamic>())];
  }

  /// Спортсмен — владелец своей базы, прямой REST без RPC (в отличие от
  /// `CoachTaskService.setStatus`, которому нужен токен доступа к ЧУЖОЙ
  /// базе). 'removed' — тот же статус, что ставит тренер: карточка
  /// остаётся видна (решение из `t.removed` в task_models.dart — "снято
  /// тренером"/сортировка в конец), просто становится недоступна.
  Future<void> setStatus(String taskId, String status) =>
      auth.rest('PATCH', 'tasks?id=eq.$taskId', body: {'status': status});

  Future<TaskPlan?> byId(String id) async {
    final rows = (await auth.rest(
            'GET', 'tasks?id=eq.$id&select=*,task_stages(*,task_steps(*)),task_runs(id,started_at,finished_at,status)'))
        as List;
    return rows.isEmpty ? null : TaskPlan.fromJson((rows.first as Map).cast<String, dynamic>());
  }

  /// Прохождение целиком одним запросом; возвращает id прохождения.
  Future<String> submitRun(Map<String, dynamic> run) async =>
      '${await auth.rest('POST', 'rpc/athlete_submit_run', body: {'p_run': run})}';

  Future<void> saveReport(String runId, String kind, String content, {String? model, String? request}) =>
      auth.rest('POST', 'task_reports', body: {
        'run_id': runId,
        'kind': kind,
        'content': content,
        if (model != null) 'model': model,
        if (request != null) 'request': request
      });

  Future<List<Map<String, dynamic>>> reports(String runId) async => [
        for (final r in (await auth.rest('GET', 'task_reports?run_id=eq.$runId&order=created_at')) as List)
          (r as Map).cast<String, dynamic>(),
      ];

  /// Адрес устройства для push заданий (повторная запись того же — без дублей).
  Future<void> registerDevice(String fcmToken) async {
    try {
      await auth.rest('POST', 'task_devices?on_conflict=token',
          body: {'token': fcmToken, 'updated_at': DateTime.now().toUtc().toIso8601String()});
    } catch (_) {
      // уже есть или нет сети — не страшно
    }
  }

  /// Push тренерам «задание выполнено».
  Future<void> notifyDone(TaskPlan task, String athleteName) async {
    final jwt = await auth.ensureFreshToken();
    if (jwt == null || task.id == null) return;
    await TaskPush.send({
      'db': auth.url,
      'key': auth.anonKey,
      'jwt': jwt,
      'kind': 'done',
      'taskId': task.id,
      'title': task.title,
      'who': athleteName,
    });
  }
}

/// Задания со стороны тренера — по токену каждого спортсмена.
class CoachTaskService {
  final CoachAccessService access;
  CoachTaskService(this.access);

  /// Отправить задание спортсмену; возвращает id задания в его базе.
  Future<String> create(CoachAthlete a, TaskPlan plan) async =>
      '${await access.rawRpc('coach_create_task', {'p_token': a.token, 'p_task': plan.toJson()}, athlete: a)}';

  Future<void> setStatus(CoachAthlete a, String taskId, String status) =>
      access.rawRpc('coach_set_task_status', {'p_token': a.token, 'p_task_id': taskId, 'p_status': status}, athlete: a);

  Future<List<TaskPlan>> list(CoachAthlete a, {String? taskId}) async {
    final rows = await access.rawRpc('coach_get_tasks', {'p_token': a.token, if (taskId != null) 'p_task_id': taskId},
        athlete: a);
    return [for (final r in (rows as List? ?? const [])) TaskPlan.fromJson((r as Map).cast<String, dynamic>())];
  }

  Future<void> registerDevice(CoachAthlete a, String fcmToken) async {
    try {
      await access.rawRpc('register_coach_device', {'p_token': a.token, 'p_fcm': fcmToken}, athlete: a);
    } catch (_) {}
  }

  /// Push спортсмену: 'new' | 'removed' | 'reminder'.
  Future<void> push(CoachAthlete a, String kind, String taskId, String title) => TaskPush.send({
        'db': a.url,
        'key': a.anonKey,
        'token': a.token,
        'kind': kind,
        'taskId': taskId,
        'title': title,
      });
}

/// Отправка push заданий через сервер звонков (/task-push) — не мессенджер.
class TaskPush {
  static Future<void> send(Map<String, dynamic> body) async {
    try {
      await http
          .post(Uri.parse('${CallService.url}/task-push'),
              headers: {'Content-Type': 'application/json'}, body: jsonEncode(body))
          .timeout(const Duration(seconds: 20));
    } catch (_) {
      // push — дополнение: задание всё равно видно при открытии раздела
    }
  }
}
