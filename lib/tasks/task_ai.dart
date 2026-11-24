import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;

import '../services/ai_service.dart';
import '../services/ai_settings.dart';
import 'task_models.dart';

/// ИИ для заданий: сборка плана из слов тренера (с уточняющими вопросами) и
/// отчёты по выполнению. Правила — справочник assets/ai/tasks_guide.md внутри
/// приложения. ИИ ничего не пишет в сырые данные — только возвращает текст.
class TaskAi {
  final AiSettings settings;
  TaskAi(this.settings);

  static String? _guide;
  static Future<String> guide() async =>
      _guide ??= await rootBundle.loadString('assets/ai/tasks_guide.md');

  /// Черновик задания или вопросы. [answers] — уже заданные вопросы и ответы
  /// тренера. [profileInfo] — профиль стрелка (анкета + последние упражнения:
  /// вид оружия, дистанция, положение, выстрелов в серии), отзыв 23.11 №2:
  /// «мой профиль не читал» — известное из профиля спрашивать нельзя.
  Future<({List<String> questions, TaskPlan? plan})> build({
    required String coachText,
    required List<({String question, String answer})> answers,
    String athletesInfo = '',
    String profileInfo = '',
  }) async {
    final reply = await AiService(settings).ask(
      systemPrompt:
          'You help a rifle/pistol shooting coach compose a task for an athlete in the app. '
          'Below is a reference on how tasks are structured. Read the coach description and the answers to clarifying questions.\n'
          // Отзыв 24.11: в контексте передаётся и разряд — учитывать его
          // при подборе нагрузки, нормативов и целей.
          'ATHLETE PROFILE (if given in the context) is already known: the rank (sports class), '
          'the disciplines (weapon), '
          'usual targets/distances and positions, shots in a series from the profile and recent exercises. '
          'Do NOT ask about anything the profile, the coach description or the previous answers already say '
          '(rank, weapon, distance, position, shots in a series) — take these values directly; in particular, '
          'if the position is already known (for example, the athlete only trains standing), never ask about it again. '
          'If the STRUCTURE cannot be built correctly without clarification — return JSON {"questions": ["…", "…"]} '
          '(1-4 short questions, only about the structure and what is unclear; do not repeat a question that was '
          'already asked or is answered by the profile). Otherwise return JSON {"task": {…}} strictly in '
          'the reference format. coach_text is the coach text in full, as written. Answer with JSON only. '
          'Write every human-readable value (titles, instructions, questions) in the language of the coach description.\n\n'
          '${await guide()}',
      contextBlock: [
        if (athletesInfo.isNotEmpty) 'Athletes: $athletesInfo',
        // Отзыв 23.11 №2: профиль стрелка — в контекст запроса, чтобы ИИ
        // не спрашивал вид оружия, дистанцию, положение и серии повторно.
        if (profileInfo.isNotEmpty)
          'ATHLETE PROFILE (already known — do not ask):\n$profileInfo',
      ].join('\n'),
      history: [
        (
          role: 'user',
          text: 'Coach description:\n$coachText'
              '${answers.isEmpty ? '' : '\n\nClarifications:\n${answers.map((a) => 'Q: ${a.question}\nA: ${a.answer}').join('\n')}'}',
        ),
      ],
      json: true,
      accept: (t) => t.contains('"task"') || t.contains('"questions"'),
    );
    final j = _json(reply.text);
    final qs = [for (final q in (j['questions'] as List? ?? const [])) '$q'];
    final task = j['task'];
    if (task is Map) {
      final plan = TaskPlan.fromJson({
        ...task.cast<String, dynamic>(),
        'stages': task['stages'] ?? const []
      });
      // Отзыв 23.11 №3: модель вернула «задание» без этапов — это пустышка,
      // а не результат. Падаем в ошибку: экран покажет её и оставит тренеру
      // черновик с уже введёнными данными, а не пустой план.
      if (plan.stages.isEmpty) {
        throw const FormatException('ИИ вернул задание без этапов');
      }
      if (plan.coachText.isEmpty) plan.coachText = coachText;
      plan.clarifications.addAll(answers);
      return (questions: const <String>[], plan: plan);
    }
    if (qs.isEmpty)
      throw const FormatException('ИИ не вернул ни задание, ни вопросы');
    return (questions: qs, plan: null);
  }

  /// Два отчёта по прохождению: текст для базы и наглядный (блоки
  /// текст/график/таблица, JSON). [runJson] — всё, что сохранено (план,
  /// выстрелы, отметки, отклонения, итоговая заметка).
  Future<({String structured, String visual, String model})> reports(
      TaskPlan plan, Map<String, dynamic> runJson,
      {String request = ''}) async {
    final data = jsonEncode({'task': plan.toJson(), 'run': runJson});
    final ai = AiService(settings);
    final structured = await ai.ask(
      systemPrompt:
          'Write a report on the athlete completing the task — for storage in a database and for another AI to read. '
          'Structured text with sections: Plan; Actual result for every step (result, time, shots, '
          'the athlete notes in their own words); Deviations (with plan/actual figures and a possible cause); '
          'The athlete final note; Conclusions and recommendations for the coach. Invent nothing — use only the data. '
          'Write in the language of the task text.\n\n'
          '${await guide()}',
      contextBlock: 'DATA:\n$data',
      history: const [(role: 'user', text: 'Write the report.')],
    );
    final visual = await ai.ask(
      systemPrompt:
          'Make a visual report on the athlete completing the task. Answer with JSON ONLY '
          '{"blocks": [ … ]}, where a block is {"type":"text","text":"…"} or {"type":"chart","chart":{…}}. '
          'chart: {"type":"line"|"bar"|"pie"|"table","title":"…","x":[…],"series":[{"name":"…","values":[…]}]}; '
          'for a table — "columns":[…],"rows":[[…]]. Combine short texts, charts by series/steps and '
          'tables. Real data only. Write texts and titles in the language of the task text. '
          '${request.isEmpty ? '' : 'Format request: $request'}',
      contextBlock: 'DATA:\n$data',
      history: const [(role: 'user', text: 'Make the visual report.')],
      json: true,
      accept: (t) => t.contains('"blocks"'),
    );
    return (
      structured: structured.text.trim(),
      visual: jsonEncode(_json(visual.text)),
      model: structured.model
    );
  }

  static Map<String, dynamic> _json(String text) {
    final a = text.indexOf('{');
    final b = text.lastIndexOf('}');
    if (a < 0 || b <= a) throw const FormatException('ИИ ответил не JSON');
    return (jsonDecode(text.substring(a, b + 1)) as Map)
        .cast<String, dynamic>();
  }
}
