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

  /// Черновик задания или вопросы. [answers] — уже заданные вопросы и ответы тренера.
  Future<({List<String> questions, TaskPlan? plan})> build({
    required String coachText,
    required List<({String question, String answer})> answers,
    String athletesInfo = '',
  }) async {
    final reply = await AiService(settings).ask(
      systemPrompt:
          'Ты помогаешь тренеру по пулевой стрельбе собрать задание для спортсмена в приложении. '
          'Ниже справочник, как устроены задания. Прочитай описание тренера и ответы на уточнения.\n'
          'Если без уточнения нельзя правильно собрать СТРУКТУРУ — верни JSON {"questions": ["…", "…"]} '
          '(1–4 коротких вопроса, только о структуре и неясном). Иначе верни JSON {"task": {…}} строго по '
          'формату справочника. coach_text — исходный текст тренера целиком. Отвечай только JSON.\n\n'
          '${await guide()}',
      contextBlock: athletesInfo.isEmpty ? '' : 'Спортсмены: $athletesInfo',
      history: [
        (
          role: 'user',
          text: 'Описание тренера:\n$coachText'
              '${answers.isEmpty ? '' : '\n\nУточнения:\n${answers.map((a) => 'В: ${a.question}\nО: ${a.answer}').join('\n')}'}',
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
          'Составь отчёт о выполнении задания стрелком — для хранения в базе и чтения другим ИИ. '
          'Структурированный текст с разделами: План; Факт по каждому этапу (результат, время, выстрелы, '
          'отметки спортсмена своими словами); Отклонения (с цифрами план/факт и возможной причиной); '
          'Итоговая заметка спортсмена; Выводы и рекомендации тренеру. Ничего не выдумывай — только из данных.\n\n'
          '${await guide()}',
      contextBlock: 'ДАННЫЕ:\n$data',
      history: const [(role: 'user', text: 'Составь отчёт.')],
    );
    final visual = await ai.ask(
      systemPrompt:
          'Сделай наглядный отчёт о выполнении задания стрелком. Ответ — ТОЛЬКО JSON '
          '{"blocks": [ … ]}, где блок — {"type":"text","text":"…"} или {"type":"chart","chart":{…}}. '
          'chart: {"type":"line"|"bar"|"pie"|"table","title":"…","x":[…],"series":[{"name":"…","values":[…]}]}; '
          'для таблицы — "columns":[…],"rows":[[…]]. Сочетай короткие тексты, графики по сериям/этапам и '
          'таблицы. Только настоящие данные. ${request.isEmpty ? '' : 'Пожелание к формату: $request'}',
      contextBlock: 'ДАННЫЕ:\n$data',
      history: const [(role: 'user', text: 'Сделай наглядный отчёт.')],
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
