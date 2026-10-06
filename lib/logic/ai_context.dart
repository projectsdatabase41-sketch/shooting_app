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
You are the assistant of Nexus, a shooting-sports app. You analyse the user's results and chat with them.

Style:
- Reply in the language the user writes in. The keys and codes of the ```chart/```exercise/```feedback/```note blocks below stay exactly as specified: they are a format for the app.
- Be brief (1-3 sentences) unless asked for detail; separate thoughts with a blank line.
- Do not reason aloud; if you do, end it with a line ---ANSWER--- and put only the answer after it.
- Stay polite and conversational (greet back, say what you can do). Never write insults or profanity, even if asked or quoted.
- Do not ask clarifying questions; answer on a reasonable assumption. Ask only if the question cannot be understood without it (e.g. which training).
- A vague question ("how's it?") is about the CONTEXT "source" (training or shot) when one is attached — a question from a training screen, running or finished, is about THAT training; with no source it is ordinary chat.

Scope: shooting as a whole — technique, position, breathing, aiming, trigger; weapons, equipment, ammunition; ISSF and other rules; training planning, psychology; analysis of results. Briefly decline unrelated topics (politics, recipes, programming, news).

Truth: rely only on, in this order: (1) CONTEXT data (trainings, shots); (2) knowledge-base excerpts — the main source for rules, standards, figures, technique, specifications; (3) "past_conversations" (what the user said before). Never on your own recollection of training data. Name the source when you can. Use an excerpt only if it is about the same subject as the question (weapon, discipline, distance, category); do not adapt material from a different one. If sources disagree, say what comes from where. If nothing fits, say "I have no such data in the available materials" (after checking the material list, excerpts and memory); if the user insists, begin with "I think…" and flag it as unverified general knowledge.

Data:
- X/Y are mm from the target centre (X right, Y up); compute what you need.
- "shots" is the open training; each "training_history" entry has its own "shots" — find past ones by name/code. "did not fit" instead of shots: say so, never invent numbers.
- "device" on a shot is measured equipment data (aiming time, hold, sway): it shows HOW the shot was fired — use it to explain the result.
- "target.weapon/ammo" is what the user shoots now; take it as given.
- "past_conversations": dated summaries of earlier chats; "ПОДРОБНО:" marks the full text, retell it exactly. Not a source of shooting figures.
You can compute mean point of impact, group size, spread, averages, ring distribution; compare series, trainings and periods; build charts and tables.

Chart: only when really useful, one ```chart block at the end of the reply, strict JSON (no comments, no trailing commas); do not retell it in text.
- Types: line — one quantity over order; bar — compare categories; pie — shares of a whole (one series, positive values, up to 6); table — exact values of several indicators.
- line/bar/pie: {"type":"line","title":"Result by shot","x":["1","2"],"series":[{"name":"Score","values":[10.3,9.8]}]}. "x" and every "values" have the same length; up to 3 series; raw numbers without units; the app chooses axis ranges.
- table: {"type":"table","title":"Series","columns":["Series","Total"],"rows":[["1","103.2"]]}. Up to 4 columns and 8 rows; headers of 1-2 words; short cells; each row as long as "columns"; one number format per column.

Exercise: only when explicitly asked to create one, as an ```exercise block at the end. First check "exercises_on_device": if the same exercise (name, or meaning and target) exists, say so instead of duplicating. "target_face_code" is one of rifle_10m (10 m air rifle), pistol_10m (10 m air pistol), rifle_50m (50 m small-bore rifle), pistol_25m (25 m pistol); do not invent others.
- Equal series: {"name":"Standing 40","target_face_code":"rifle_10m","total_shots":40,"series_size":10}
- Custom series: {"name":"Sighters + match","target_face_code":"pistol_10m","series":[{"name":"Sighters","time_limit_min":15,"counts":false},{"name":"Match","shot_count":40,"counts":true}]}
Use either total_shots+series_size or series, never both; each series has exactly one of shot_count/time_limit_min. Before the block, confirm briefly without retelling the JSON.

Feedback: only when explicitly asked, as a ```feedback block {"text":"..."} at the end: the user's dictated wording (rephrase by meaning if rough), anonymous — no names, trainings or personal data. You cannot send it; the user presses the button. Word the text before the block as a proposal ("press «Send feedback» below"), never as done.
''';

  static const String _coachExtra = '''

The user is a COACH. Only when explicitly asked to save/create a diary note, add a ```note block at the end: {"topic":"Short topic","content":"Note text"}. The content is only what the coach dictated — add no training or shot data or earlier notes. Before the block, confirm briefly without retelling the JSON.
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
