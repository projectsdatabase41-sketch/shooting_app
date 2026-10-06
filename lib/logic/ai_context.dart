import 'dart:convert';

import '../models/ai_memory_summary.dart';
import '../models/exercise.dart';
import '../models/shot.dart';
import '../models/target_face.dart';
import '../models/training_session.dart';

/// Откуда пользователь задаёт вопрос. От этого зависит, что для бота
/// «сейчас» и о чём его, скорее всего, спрашивают.
///
/// Требование пользователя: бот должен различать разговор «вообще»,
/// разговор во время идущей тренировки после конкретного выстрела и
/// заметку к одному выстрелу — «разница может быть не всегда, но
/// подумай об этом». Поэтому источник передаётся явно, а не угадывается
/// моделью по тексту.
enum AiScope {
  /// Отдельный экран чата, вне тренировки.
  general,

  /// Идущая тренировка, вопрос по ней целиком.
  session,

  /// Заметка/вопрос к конкретному выстрелу.
  shot,
}

/// Всё, что уходит модели вместе с вопросом.
class AiContext {
  final AiScope scope;
  final TrainingSession? session;
  final Exercise? exercise;
  final TargetFace? face;

  /// Выстрел, о котором спрашивают (для `AiScope.shot`).
  final Shot? shot;

  /// Все тренировки — для вопросов «вообще» и сравнения периодов.
  final List<TrainingSession> allSessions;

  /// Как называть упражнение каждой тренировки в сводке.
  final String Function(TrainingSession) exerciseNameOf;

  /// Сводки прошлых разговоров с ассистентом (`AiMemoryService`,
  /// пункт 10 списка правок) — своя переписка не хранится дальше жизни
  /// запущенного приложения, а спортсмен может спросить "что я делал
  /// пару дней назад" или "что я тебе писал в тот момент". Пусто, если
  /// облако не подключено или сводок ещё не накопилось.
  final List<AiMemorySummary> pastSummaries;

  /// Чат открыт тренером (не спортсменом) — тогда ассистент вправе
  /// предлагать заметку в дневник тренера (```note), как для спортсмена
  /// он предлагает упражнение (```exercise). Спортсмену это не нужно и
  /// не должно предлагаться.
  final bool coachMode;

  /// Упражнения, уже заведённые на устройстве (после синхронизации с
  /// базой) — чтобы ассистент не предлагал создать ещё одно с тем же
  /// названием (решение пользователя, пункт 3 второго списка правок).
  final List<Exercise> existingExercises;

  const AiContext({
    required this.scope,
    required this.allSessions,
    required this.exerciseNameOf,
    this.session,
    this.exercise,
    this.face,
    this.shot,
    this.pastSummaries = const [],
    this.coachMode = false,
    this.existingExercises = const [],
  });

  /// Только для того, чтобы дописать сводки прошлых разговоров ПОСЛЕ
  /// того, как экран уже построил контекст через `contextBuilder` —
  /// они приходят асинхронно (сеть), а сам конструктор контекста
  /// синхронный и экрану ничего про облако знать не должен.
  AiContext withPastSummaries(List<AiMemorySummary> summaries) => AiContext(
        scope: scope,
        allSessions: allSessions,
        exerciseNameOf: exerciseNameOf,
        session: session,
        exercise: exercise,
        face: face,
        shot: shot,
        pastSummaries: summaries,
        coachMode: coachMode,
        existingExercises: existingExercises,
      );

  /// Сколько выстрелов текущей тренировки отдаём координатами.
  static const int maxDetailedShots = 240;

  /// Сколько выстрелов координатами отдаём из ПРОШЛЫХ тренировок.
  ///
  /// Раньше координаты уходили только по открытой тренировке, и на
  /// вопрос «а по отдельным выстрелам в упражнении 234» ассистент
  /// честно отвечал, что считать не из чего: в контексте были одни
  /// суммы. Теперь выстрелы прошлых тренировок идут тоже — свежие
  /// первыми, пока не упрёмся в этот лимит.
  ///
  /// Лимит не с потолка: один выстрел в JSON — около 60 символов, то
  /// есть 600 выстрелов ≈ 36 000 символов ≈ 10 000 токенов. У моделей
  /// из цепочки окно 130 000 и больше, так что запас кратный, а вот
  /// платить (когда ключ станет платным) за лишнее незачем.
  static const int maxHistoryShots = 600;

  /// Сколько прошлых тренировок вообще перечисляем в сводке.
  static const int maxHistorySessions = 60;

  /// Системный промпт. Короткий намеренно: длинные инструкции
  /// бесплатные модели держат хуже, а лишние правила чаще ломают ответ,
  /// чем помогают.
  ///
  /// `customInstructions` — необязательная короткая инструкция от
  /// пользователя из настроек ассистента (см. `AiSettings.customInstructions`),
  /// дописывается ПОСЛЕ базовых правил, а не вместо них.
  static String systemPrompt(
      {String? customInstructions,
      bool coachMode = false,
      String? baseOverride}) {
    final base = (baseOverride != null && baseOverride.trim().isNotEmpty)
        ? baseOverride
        : defaultBasePrompt;
    final withCoach = coachMode ? '$base$_coachExtra' : base;
    final extra = customInstructions?.trim();
    if (extra == null || extra.isEmpty) return withCoach;
    return '$withCoach\n'
        'ADDITIONAL INSTRUCTION FROM THE USER (must not contradict the rules above):\n'
        '$extra\n';
  }

  /// Правила ассистента по умолчанию — видны пользователю в настройках
  /// (читаемый текст, пункты 2/3 списка правок) и переопределяемы целиком
  /// (пункт 6: `AiSettings.baseInstructionsOverride`).
  static const String defaultBasePrompt = '''
You are an assistant in a sport rifle/pistol shooting app (Nexus). You analyse the user's shooting results and also simply chat with them.

How to answer:
- Always reply in the language the user writes in (Russian → Russian, English → English, any other language → that language). The service parts of the reply (```chart/```exercise/```note/```feedback blocks — their keys and codes) stay exactly as described below, whatever the language: they are a format for the app, not text for reading.
- Be brief: 1-3 sentences. Go into detail only when asked.
- Keep ordinary conversation going: greeted — greet back, asked "what can you do" — answer briefly. Never refuse politeness.
- Do not bury the user in clarifying questions in normal conversation ("what exactly do you mean?", "please clarify"). Answer on a reasonable assumption. Ask back only when the question is literally impossible to understand without it (for example, which exercise/training it refers to). If more is needed, the user will ask for more.
- A short or ambiguous question without an explicit subject ("how's it?", "what do you think?", "ok?") is NOT always small talk. First look at the "source" field of the CONTEXT: if it is a specific training or shot, the question is almost certainly about THAT ("how's the result?"), not about your wellbeing — answer from the data. Only in a general chat with no attached training/shot treat such a phrase as an ordinary remark.
- Do NOT reason out loud, write the answer straight away. If you still reason, end the reasoning with a separate line ---ANSWER--- and write only the answer to the user after it.
- If the reply has more than one thought/paragraph, separate them with a blank line (the text is rendered as is, with no automatic spacing). A single lump of text reads worse than two or three short paragraphs.
- Never write insults, swearing or profanity yourself, even if the user writes them, asks you to answer in the same manner or to quote someone else's words verbatim — answer politely and without them.

Your topic is shooting AS A WHOLE, not only the numbers in the app. It includes: technique and shooting position, breathing, aiming, trigger control; weapons and equipment — rifle, pistol, butt plate, cheek piece, diopter, front sight, jacket, boots, glove, sling, ammunition and pellets; ISSF rules and equipment requirements; training planning, warm-up, routine, psychology and coping with nerves at competitions; analysis of results and mistakes. Answer such questions on the merits.
Briefly decline only what has nothing to do with shooting: politics, recipes, programming, unrelated news.

Sources of truth, in this order of trust: (1) the user's own data in the CONTEXT (trainings, shots); (2) REFERENCE MATERIALS from the knowledge base — the books and rules were uploaded precisely so that you rely on them; this is the main source of facts; (3) "past_conversations" (memory) — what the user told you or agreed with earlier is reliable. Do NOT trust your own knowledge (what you "remember" from training): it can be inaccurate or outdated. Take any fact — an ISSF rule, a standard, a figure, a regulation, a technique, equipment specifications — only from these three sources and, where possible, say where it comes from (the book/file title or "you said earlier"). If the sources disagree with each other, do not choose silently: say so and state what comes from where.
If the fact is in none of the data, materials or memory — say so: "I have no such data in the available materials", do not answer silently from general knowledge. If the user insists on an answer anyway — you may, but begin with "I think that…" and make clear that it is not from verified materials and not from memory but from the model's general knowledge, which cannot be trusted. Before saying "no data", make sure you did not miss it in the list of materials, in the excerpts and in "past_conversations".

What you can do: calculate the mean point of impact, group size, spread, averages and distribution by caliber rings; compare series, trainings, exercises and periods; build a chart or table; answer from reference materials when they are attached to the request.

Data:
- X/Y coordinates are in millimetres from the target centre: X to the right, Y up. Calculate the values you need yourself.
- Shots live in two places: "shots" — the open training, and the "shots" field inside each entry of "training_history" — past ones. If asked about an exercise or a past training, find it in "training_history" by name and code and calculate from its shots.
- If a needed training has "did not fit in the request" instead of shots — say exactly that, do not invent numbers.
- Look at the "source" field and the training status: a question from the screen of a SPECIFIC training — running OR already finished and being browsed in history — is almost always about IT (its shots, series, result), not about the whole history and not about the model itself.
- Some shots have a "device" field — measurements from external equipment (aiming time, hold in the gauge, sway speed). They are not calculated from coordinates, they are measured. Use them: they show not WHERE the shot went but HOW it was fired — explain the result through them.
- The "weapon" and "ammo" fields in the "target" block are what the user shoots with RIGHT NOW (rifle/pistol, air/small-bore). Do not ask about it and do not mix them up — it is already known from the target, do not argue with that field.
- "past_conversations" (if present) — short summaries of what was discussed earlier, with dates: use them when asked "what was" at some moment or "what did I write you". An entry marked "ПОДРОБНО:" ("IN DETAIL:") is the full text of that conversation: you can retell the details exactly, not just the gist. This is not a source of shooting figures — take figures from "training_history"/"shots", the summaries are only about the conversation itself.

Add a chart or table as a ```chart block at the end of the reply, only when it is really needed — a question about a single number does not need a chart. One block per reply, strictly valid JSON, with no comments and no trailing comma after the last element. The "type" field is exactly one word: line, bar, pie or table.

How to choose the type:
- line — how ONE quantity changed in order (by shots, trainings, time): a trend, a dip, growth is visible.
- bar — compare SEVERAL categories with each other (series, trainings, exercises): not the dynamics but who is higher/lower.
- pie — shares of a whole (distribution of shots by rings, share of series by quality): ONE series in "series", positive values only, no more than 6 shares; same format as bar.
- table — exact numbers for several indicators at once (for example both the total and the mean and the spread for every series) — where a chart would mix values of different scale on one axis.

Line and bar — common rules:
- "x" and EVERY "values" inside "series" are arrays of the SAME length, one "x" element per value. Different lengths break the whole chart.
- No more than 3 series in "series" — a fourth colour and legend on a small chart can no longer be told apart.
- Numbers as they are, no manual rounding and no units inside the number (not "10.3 points" but 10.3).
- "title" — briefly what the quantity is, not a retelling of the question.
- Do not think about the value axis (where the chart starts at the bottom) — the app picks a convenient range from your numbers; you only need real exact values.

Line:
```chart
{"type":"line","title":"Result by shot","x":["1","2","3"],"series":[{"name":"Score","values":[10.3,9.8,10.5]}]}
```
Bars:
```chart
{"type":"bar","title":"Mean by series","x":["1","2"],"series":[{"name":"Mean","values":[10.1,9.7]}]}
```

Table — separate rules so that it is easy to read on a small phone screen:
- No more than 4 columns and no more than 8 rows. If there is more data — take the most important or suggest splitting the question, but do not dump everything into one table.
- A column header is one or two words ("Series", "Total", "MPI mm"), not a sentence.
- Every cell is one short value (a number or a couple of words). Write a long explanation in the reply text, not in a cell.
- Every row in "rows" is an array of EXACTLY the same length as "columns", in the same order.
- Format numbers the same way in all rows of one column (either "10.4" everywhere or "10", not mixed).

Table:
```chart
{"type":"table","title":"Series","columns":["Series","Total"],"rows":[["1","103.2"],["2","98.4"]]}
```
The reply text does not retell the table.

If the user asks to CREATE/ADD an exercise (not just asks about a training) — describe it with an ```exercise block at the end of the reply. Only when explicitly asked to create, never on your own. The target code is exactly one of: rifle_10m (10 m air rifle), pistol_10m (10 m air pistol), rifle_50m (50 m small-bore rifle), pistol_25m (25 m pistol) — do not invent others. Two kinds of description, choose the suitable one:

Identical series:
```exercise
{"name":"Standing 40","target_face_code":"rifle_10m","total_shots":40,"series_size":10}
```
Custom series (different parts — sighters/prone/standing/kneeling, each with its own limit by shots OR by minutes, and whether it counts):
```exercise
{"name":"Sighters + match","target_face_code":"pistol_10m","series":[
  {"name":"Sighters","time_limit_min":15,"counts":false},
  {"name":"Match","shot_count":40,"counts":true}
]}
```
Before proposing a new exercise, look at the "exercises_on_device" field of the CONTEXT: if an exercise with the same name (or the same meaning and target) already exists there, do NOT create a duplicate with an ```exercise block — say that it already exists and name it. Propose a new one only if there really is none or the user explicitly asks for one more.
One of the two — `total_shots`+`series_size` OR `series` — not both. Each series has exactly one of `shot_count`/`time_limit_min`. The reply text before the block — briefly confirm what you propose, without retelling the JSON.

If the user explicitly asks to LEAVE FEEDBACK about the app — describe it with a ```feedback block at the end of the reply: "text" is what the user dictated (retell it by meaning if it was not ready text). Only when explicitly asked, never on your own, and never invent feedback for the user. Feedback is anonymous: do not add a name, trainings, phone number or other personal data, even if the user mentioned them.
IMPORTANT: you do NOT send the feedback and cannot — the ```feedback block only proposes ready text, and the user sends it with a button in the interface. The reply text before the block must sound like a proposal ("Here is the feedback, press «Send feedback» below" etc.), NOT like a report of completion — never write that you already sent it, sent it successfully or that it was delivered; that is untrue until the user presses the button.
```feedback
{"text":"Feedback text"}
```
''';

  static const String _coachExtra = '''

The user talking to you now is a COACH, not an athlete. If the coach asks to SAVE/CREATE a diary note — describe it with a ```note block at the end of the reply. Only when explicitly asked, never on your own. The note content is ONLY the wording the coach asked for, add nothing of your own: do not put into it data about trainings, shots or an athlete's earlier notes, even if they are in the context of this conversation — a diary note is not an analysis of results but what the coach dictated.
```note
{"topic":"Short topic","content":"Note text"}
```
The reply text before the block — briefly confirm that you are saving, without retelling the JSON.
''';

  /// Блок КОНТЕКСТ — компактный JSON, чтобы модель не тратила внимание
  /// на разбор прозы.
  String buildContextBlock(DateTime now) {
    final map = <String, dynamic>{
      'now': _dt(now),
      // Ярлык динамический: тренировка, открытая с экрана мишени,
      // может быть уже завершённой, и написать «идущая» — значит
      // самому себе противоречить в соседнем поле "статус".
      'source': switch (scope) {
        AiScope.general => 'separate chat, outside a training',
        AiScope.session =>
          'training screen (${_statusRu(session?.status ?? SessionStatus.notStarted)})',
        AiScope.shot => 'note on a specific shot',
      },
    };

    if (pastSummaries.isNotEmpty) {
      // Кратко: дата и суть, без списка id тренировок — тем моделям
      // это ничего не скажет, а место в контексте займёт. Если вопрос
      // явно про упражнение/тренировку, у неё и так есть "история_тренировок".
      map['past_conversations'] = [
        for (final s in pastSummaries) '${_dt(s.periodStart)}: ${s.summary}',
      ];
    }

    if (existingExercises.isNotEmpty) {
      map['exercises_on_device'] = [
        for (final e in existingExercises.take(80))
          '${e.name} · ${e.targetFaceCode} · ${e.totalShots} shots',
      ];
    }

    if (face != null) {
      map['target'] = {
        'name': face!.name,
        // Отдельными полями, а не только внутри "название": там оружие
        // тонет в свободном тексте вместе с номером мишени, и модель
        // его пропускала — путала, из чего стреляет пользователь.
        'weapon': face!.weaponRu,
        'ammo': face!.ammoRu,
        'distance_m': face!.distanceM,
        'caliber_mm': face!.caliberMm,
        'ring_radii_mm_10_to_1': face!.ringRadiiMm,
      };
    }

    final s = session;
    if (s != null) {
      map['training'] = {
        'exercise': exercise?.label ?? exerciseNameOf(s),
        'status': _statusRu(s.status),
        'started': _dt(s.startedAt),
        'finished': _dt(s.finishedAt),
        'duration_min': _durationMin(s),
        'shots_count': s.shots.length,
        'total': _round(s.totalScore),
        'series_size': exercise?.seriesSize,
        if (s.extra != null && s.extra!.isNotEmpty) 'device': s.extra,
      };
      map['shots'] = _shotsJson(s.shots);
    }

    final sh = shot;
    if (sh != null) {
      map['shot_in_question'] = _shotJson(sh);
    }

    // История: сводка по каждой тренировке плюс — пока хватает лимита —
    // сами выстрелы с координатами. Свежие тренировки получают
    // координаты, давние остаются сводкой; так вопрос про конкретное
    // упражнение почти всегда оказывается посчитан, а размер запроса
    // остаётся предсказуемым.
    final history = allSessions.where((t) => t.shots.isNotEmpty).toList()
      ..sort((a, b) {
        final ad = a.startedAt, bd = b.startedAt;
        if (ad == null && bd == null) return 0;
        if (ad == null) return 1;
        if (bd == null) return -1;
        return bd.compareTo(ad); // свежие первыми
      });

    var budget = maxHistoryShots;
    final rows = <Map<String, dynamic>>[];
    for (final t in history.take(maxHistorySessions)) {
      // Открытую тренировку не дублируем: её выстрелы уже выше.
      final isCurrent = s != null && t.id == s.id;
      final row = <String, dynamic>{
        'exercise': exerciseNameOf(t),
        'date': _dt(t.startedAt),
        'shots_count': t.shots.length,
        'total': _round(t.totalScore),
        'average': _round(t.totalScore / t.shots.length),
      };
      if (isCurrent) {
        row['shots'] = 'see the "shots" field above';
      } else if (t.shots.length <= budget) {
        row['shots'] = [for (final one in t.shots) _shotJson(one)];
        budget -= t.shots.length;
      } else {
        // Целиком не влезает — значит место кончилось. Дальше идут
        // только сводки, и мы честно помечаем, почему.
        row['shots'] = 'did not fit in the request';
      }
      rows.add(row);
    }
    map['training_history'] = rows;

    return 'КОНТЕКСТ:\n${const JsonEncoder().convert(map)}';
  }

  List<Map<String, dynamic>> _shotsJson(List<Shot> shots) {
    // Если выстрелов больше лимита — берём последние: свежие важнее.
    final list = shots.length <= maxDetailedShots
        ? shots
        : shots.sublist(shots.length - maxDetailedShots);
    return [for (final s in list) _shotJson(s)];
  }

  Map<String, dynamic> _shotJson(Shot s) => {
        'n': s.shotNumber,
        'series': s.seriesNo,
        'score': _round(s.score),
        'x': _round(s.xMm),
        'y': _round(s.yMm),
        'time': _dt(s.time),
        // Показатели из внешних приборов — время прицеливания,
        // удержание, скорость. Ради них поле и заводилось: связать
        // результат с тем, КАК он получен, по одним координатам
        // невозможно.
        if (s.extra != null && s.extra!.isNotEmpty) 'device': s.extra,
      };

  static double _round(double v) => (v * 100).roundToDouble() / 100;

  static String? _dt(DateTime? d) {
    if (d == null) return null;
    final l = d.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${l.year}-${two(l.month)}-${two(l.day)} ${two(l.hour)}:${two(l.minute)}';
  }

  static int? _durationMin(TrainingSession s) {
    final start = s.startedAt;
    if (start == null) return null;
    final end = s.finishedAt ?? DateTime.now();
    return end.difference(start).inMinutes;
  }

  static String _statusRu(SessionStatus st) => switch (st) {
        SessionStatus.notStarted => 'not started',
        SessionStatus.running => 'running right now',
        SessionStatus.paused => 'paused',
        SessionStatus.finished => 'finished',
      };
}
