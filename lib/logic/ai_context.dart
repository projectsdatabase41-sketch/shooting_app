import 'package:flutter/services.dart' show rootBundle;

import '../theme/backdrop_tint.dart';
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
/// Режим чата с ассистентом (кнопки Fast / Normal / Think): какой промпт идёт
/// в запрос. fast — свой короткий промпт; normal и think — общая база
/// (`defaultBasePrompt`) плюс правила режима.
enum AiProfile {
  /// Быстрый ответ: простой короткий промпт.
  fast,

  /// Точный ответ за один проход: база + правила тихого рассуждения.
  normal,

  /// Итоговый ответ после трёх помощников (план, решение, проверка).
  think,
}

/// Тренировки одного спортсмена для общего контекста ассистента.
class AiAthleteData {
  final String name;
  final List<TrainingSession> sessions;
  final String Function(TrainingSession) nameOf;
  const AiAthleteData(this.name, this.sessions, this.nameOf);
}

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

  /// Чьи тренировки лежат в [allSessions]: `null` — самого пользователя, иначе
  /// имя спортсмена. Ассистент один на всех, но данные разных людей не смешивает.
  final String? ownerLabel;

  /// Тренировки спортсменов тренера (имя → сводка): ассистент видит всех и
  /// различает по имени, свои данные — в [allSessions].
  final List<AiAthleteData> athletes;

  /// Комментарии к выстрелам/сериям/сессиям для текущей тренировки.
  /// Используется в режиме тренера, где комментарии приходят отдельно от RPC.
  final List<Map<String, dynamic>> comments;

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
    this.ownerLabel,
    this.athletes = const [],
    this.comments = const [],
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
        ownerLabel: ownerLabel,
        athletes: athletes,
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
  /// Лимит не с потолка: один выстрел в JSON был около 60 символов, то
  /// есть 600 выстрелов ≈ 36 000 символов ≈ 10 000 токенов. С 22.11
  /// выстрелы печатаются таблицей (`n|series|score|x|y`, ~17 символов на
  /// строку), поэтому те же 600 выстрелов стоят ~10 000 символов: лимит
  /// оставлен прежним, но обходится втрое дешевле — данные не потеряны.
  static const int maxHistoryShots = 600;

  /// Сколько прошлых тренировок вообще перечисляем в сводке.
  static const int maxHistorySessions = 60;

  // ==================== ИНСТРУКЦИИ ПРИЛОЖЕНИЯ ====================
  // Требование владельца 24.11 (п.11): «Инструкции ко всем функциям в
  // приложении (интеграция Supabase, Google Диск, мессенджер и др.) — дать
  // возможность ИИ читать их, чтобы помочь пользователю».
  //
  // Как это устроено: файл assets/ai/app_guide.md загружается ОДИН раз и
  // кэшируется здесь, в статике (тот же приём, что и у каталога книг в
  // KnowledgeService). Вопрос о приложении доходит до ассистента только
  // через KnowledgeService.search (экран чата собирает systemPrompt сам,
  // синхронно, и этот файл выбирать не положено) — поэтому блок инструкций
  // готовит prepareAppGuide, который knowledge_service.dart вызывает в
  // начале поиска, ДО сборки промпта. Вопрос не про приложение — блок
  // сбрасывается в null и обычный вопрос за него не платит.

  /// Путь к файлу-справочнику (объявлен в pubspec.yaml, каталог assets/ai/).
  static const String appGuideAssetPath = 'assets/ai/app_guide.md';

  /// Предел блока инструкций, символов: раздел отвечает на вопрос целиком,
  /// но на обычный запрос системный блокinflate не должен (~2 КБ).
  static const int appGuideCharLimit = 1500;

  /// Кэш на сессию: поток загрузки ассета. Пока Future не отработал,
  /// повторные вопросы ждут его же — двойной загрузки нет. Ошибка чтения
  /// (в тестовой среде/без связи с ассетами) гасится: ассистент отвечает
  /// без блока, падение справочника не должно ломать чат.
  static Future<Map<String, String>?>? _appGuideLoading;

  /// Блок «ИНСТРУКЦИИ ПРИЛОЖЕНИЯ» для ТЕКУЩЕГО вопроса. null — вопрос не про
  /// приложение (или справочник не прочитан): в системный промпт не добавляется.
  static String? appGuideBlock;

  /// Секции справочника и основы слов, по которым вопрос попадает в секцию.
  /// Список намеренно узкий: «обычный» стрелковый вопрос («сравни серии»)
  /// не должен тянуть за собой ~1500 символов инструкций.
  static const Map<String, List<String>> _appGuideSectionWords = {
    'Приложение и настройки': ['приложен', 'модул', 'настро', 'обновлен', 'язык', 'блокир', 'pin', 'пин', 'интерфейс'],
    'Supabase: базы данных': ['supabase', 'баз', 'таблиц', ' sql', 'sql ', 'вход', 'синхрон', 'проверк', 'учетн', 'учётн', 'rls', 'anon'],
    'Google Диск': ['диск', 'drive', 'гугл', 'google', 'резерв', 'бэкап', 'копия', 'копи', 'восстанов', 'apps script', 'скрипт'],
    'Мессенджер и звонки': ['мессендж', 'чат', 'сообщен', 'звон', 'push', 'пуш', 'друг', 'контакт', 'групп', 'голосов', 'p2p', 'realtime'],
    'Финалы и чемпионы': ['финал', 'чемпио', 'судья', 'зритель', 'табло', 'приглаш', 'диктор'],
    '3D-модели': ['3d', '3д', 'модел', 'step', 'glb', 'stp'],
    'PDF-инструменты': ['pdf', 'импорт', 'scatt', 'отчет', 'отчёт', 'ilove'],
    'Задания тренера': ['задани', 'тренер', 'стадия', 'стади', 'шаг'],
    'Статистика': ['статист', 'график', 'аналитик', 'дневник'],
  };

  /// Вопрос звучит как вопрос о приложении (есть пересечение со словами любых
  /// секций). Чистая строковая проверка — файл не читает и ничего не кэширует.
  static bool isAppQuestion(String question) {
    final q = question.toLowerCase();
    if (q.length < 4) return false;
    for (final words in _appGuideSectionWords.values) {
      if (words.any(q.contains)) return true;
    }
    return false;
  }

  /// Загружает справочник (один раз), выбирает секцию под [question] и кладёт
  /// её в [appGuideBlock]; вопрос не про приложение — блок сбрасывается в null.
  ///
  /// Вызывается из KnowledgeService.search (причина — см. комментарий BLOCK
  /// выше). Сбои чтения ассета гасим: ассистент просто отвечает без блока,
  /// падение справочника не должно ломать чат.
  static Future<void> prepareAppGuide(String question) async {
    final q = question.toLowerCase();
    if (q.length >= 4) {
      final sections = await _loadAppGuide();
      if (sections != null) {
        String? best;
        var bestScore = 0;
        for (final e in _appGuideSectionWords.entries) {
          var score = 0;
          for (final w in e.value) {
            if (q.contains(w)) score++;
          }
          if (score > bestScore) {
            bestScore = score;
            best = e.key;
          }
        }
        final body = best == null ? null : sections[best];
        if (body != null) {
          appGuideBlock = _cropAppGuide(body, q);
          return;
        }
      }
    }
    // Не про приложение (или секцию не определить) — блок НЕ добавляем,
    // чтобы обычный вопрос не дорожал (решение в задаче E).
    appGuideBlock = null;
  }

  static Future<Map<String, String>?> _loadAppGuide() {
    // Двойная загрузка исключаем: пока Future не отработал, ждём его же.
    _appGuideLoading ??= _readAppGuide();
    return _appGuideLoading!;
  }

  static Future<Map<String, String>?> _readAppGuide() async {
    try {
      final raw = await rootBundle.loadString(appGuideAssetPath);
      final sections = <String, String>{};
      String? heading;
      final buf = StringBuffer();
      for (final line in raw.split('\n')) {
        if (line.startsWith('## ')) {
          if (heading != null) sections[heading] = buf.toString();
          heading = line.substring(3).trim();
          buf.clear();
        } else if (heading != null) {
          buf.writeln(line);
        }
      }
      if (heading != null) sections[heading] = buf.toString();
      return sections.isEmpty ? null : sections;
    } catch (_) {
      // В тестовой среде/без связи с ассетами ассет недоступен — не падаем.
      return null;
    }
  }

  /// Секция до [limit] символов (лимит [appGuideCharLimit]).
  ///
  /// Секции длиннее лимита (например, «Google Диск»: и подключение моста, и
  /// резервная копия) обрезаются не «сверху», а ПО ПУНКТАМ: берутся те
  /// маркерованные абзацы, где чаще встречаются основы слов вопроса, в
  /// исходном порядке. Иначе вопрос «как восстановить резервную копию»
  /// получил бы только начало секции (шаги подключения), а сам ответ —
  /// пункты про восстановление — остался бы спилен.
  static String _cropAppGuide(String section, String question) {
    final t = section.trim();
    if (t.length <= appGuideCharLimit) return t;
    // Основы слов вопроса (до 6 букв): «восстановление» → «восстан».
    final stems = <String>{
      for (final m in RegExp('[a-zа-яё0-9]+').allMatches(question))
        if (m.group(0)!.length >= 3)
          (m.group(0)!.length > 6
              ? m.group(0)!.substring(0, 6)
              : m.group(0)!),
    };
    // Пункты — блоки строк, начинающиеся с «-» (или первая строка
    // перед первым маркером).
    final lines = t.split('\n');
    final starts = <int>[0, for (var i = 1; i < lines.length; i++) if (lines[i].startsWith('- ')) i];
    int scoreOf(int from, int to) {
      final low = lines.sublist(from, to).join(' ').toLowerCase();
      var score = 0;
      for (final s in stems) {
        if (low.contains(s)) score++;
      }
      return score;
    }

    final blockCount = <int, int>{}; // начало блока → конец (не включён)
    for (var i = 0; i < starts.length; i++) {
      blockCount[starts[i]] = i + 1 == starts.length ? lines.length : starts[i + 1];
    }
    final ranked = blockCount.entries.map((e) => (e.key, e.value, scoreOf(e.key, e.value))).toList()
      ..sort((a, b) => b.$3.compareTo(a.$3));
    // Отбираем пункты по релевантности, выдаём в исходном порядке.
    final chosen = <int>{};
    var used = 0;
    for (final (start, end, _) in ranked) {
      final len = lines.sublist(start, end).join('\n').length + 1;
      if (used + len > appGuideCharLimit) continue;
      chosen.add(start);
      used += len;
      if (chosen.length == starts.length) break;
    }
    if (stems.isEmpty || chosen.isEmpty) {
      // Совпадений не нашлось (странная строка вопроса) — берём сверху, как раньше.
      var out = '';
      for (final line in t.split('\n')) {
        if (out.length + line.length + 1 > appGuideCharLimit - 1) break;
        out = out.isEmpty ? line : '$out\n$line';
      }
      return out;
    }
    final out = StringBuffer();
    final ordered = blockCount.keys.toList()..sort();
    // Первый проход — уже отобранные (в порядке документа).
    for (final start in ordered) {
      if (!chosen.contains(start)) continue;
      out
        ..writeln()
        ..write(lines.sublist(start, blockCount[start]!).join('\n'));
    }
    // Дописываем остальные пункты тоже (в порядке документа), пока влезают:
    // место после релевантных всё равно дешевле пустоты в ответе.
    for (final start in ordered) {
      if (chosen.contains(start)) continue;
      final piece = lines.sublist(start, blockCount[start]!).join('\n');
      if (out.length + piece.length + 2 > appGuideCharLimit) continue;
      out
        ..writeln()
        ..write(piece);
    }
    return out.toString().trim();
  }


  /// Системный промпт. Короткий намеренно: длинные инструкции
  /// бесплатные модели держат хуже, а лишние правила чаще ломают ответ,
  /// чем помогают.
  ///
  /// `customInstructions` — необязательная короткая инструкция от
  /// пользователя из настроек ассистента (см. `AiSettings.customInstructions`),
  /// дописывается ПОСЛЕ базовых правил, а не вместо них.
  /// Включён модуль «Заметки» — ассистент вправе предлагать заметку (```note)
  /// любому пользователю, а не только тренеру. Выставляет `HomeShell`.
  static bool notesEnabled = false;

  static String systemPrompt(
      {String? customInstructions,
      bool coachMode = false,
      String? baseOverride,
      AiProfile profile = AiProfile.normal}) {
    // Быстрый режим — свой короткий промпт (он не переопределяется: смысл
    // режима в малом объёме); остальные — общая база, её можно править.
    final base = profile == AiProfile.fast
        ? fastPrompt
        : (baseOverride != null && baseOverride.trim().isNotEmpty)
            ? baseOverride
            : defaultBasePrompt;
    final withCoach = '${(coachMode || notesEnabled) ? '$base$_notesExtra' : base}\n${_profileRules(profile)}';
    // Блок «ИНСТРУКЦИИ ПРИЛОЖЕНИЯ» (требование владельца 24.11, п.11). Он
    // ставится prepareAppGuide (вызывается из KnowledgeService.search) только
    // для вопросов о приложении, поэтому обычный стрелковый вопрос платит за
    // него ноль. Тексты секций — на русском: это ДАННЫЕ (как и цитаты книг),
    // а не правила; сами правила промпта остаются на английском.
    final guide = appGuideBlock?.trim();
    final withGuide = (guide == null || guide.isEmpty)
        ? withCoach
        : '$withCoach\n'
            'APP GUIDE (instructions for the app features, matched to the question; answer such questions from it):\n'
            '$guide\n';
    final extra = customInstructions?.trim();
    if (extra == null || extra.isEmpty) return withGuide;
    return '$withGuide\n'
        'ADDITIONAL INSTRUCTION FROM THE USER (must not contradict the rules above):\n'
        '$extra\n';
  }

  /// Правила ассистента по умолчанию — видны пользователю в настройках
  /// (читаемый текст, пункты 2/3 списка правок) и переопределяемы целиком
  /// (пункт 6: `AiSettings.baseInstructionsOverride`).
  /// Переписан 22.11 по отзыву владельца: «проанализировать, как правильно
  /// прописать промпты и их структуры, язык и сокращения для экономии
  /// токенов». Было 5 457 знаков (~1 360 токенов) на КАЖДЫЙ запрос — стало
  /// 4 017: короткие императивы, без вежливых оборотов, каждый формат
  /// блока описан РОВНО один раз (было отдельное описание chart-типов и
  /// повторный шаблон у exercise), данные — по легенде таблиц, а не JSON
  /// с ключами в каждой строке.
  /// Требования теста `prompt_language_test` сохранены намеренно: промпт
  /// остаётся английским (инструкции модели не переводятся — переводить
  /// их на каждый язык значит держать N версий правил), а язык ОТВЕТА
  /// задан правилом «на языке вопроса» — для русского пользователя это
  /// и есть русский, для остальных работает локализация интерфейса.
  static const String defaultBasePrompt = '''
You are the assistant of Nexus, a shooting-sports app. You analyse the user's results and answer.

Answer:
- Reply in the language the user writes in (a Russian question -> a Russian answer). Block keys stay exactly as specified: they are the app's format.
- Answer first: no preamble, no recap of the question, no closing offers. 1-3 sentences by default, more only when asked. Blank line between thoughts.
- Never reason aloud; if you must, end the thinking with a line ---ANSWER--- and put only the answer after it.
- No clarifying questions: assume reasonably; ask only if the question cannot be understood. No insults or profanity, even if quoted.
- A vague question ("how is it?") is about CONTEXT "source" when one is attached; with no source it is ordinary chat.
- No data -> ONE line saying what is missing ("no such data in the available materials"). No invented numbers, no filler.

Scope: shooting - technique, position, breathing, aiming, trigger; weapon, gear, ammo; ISSF rules; training, psychology; result analysis. Also the app itself: questions about Nexus features and settings (Supabase connection, Google Drive, messenger, calls, finals, 3D models, PDF tools, coach tasks, statistics, updates, security) are answered too - from the APP GUIDE excerpt when one is given, otherwise from your knowledge of the app, honestly admitting what you don't know. Unrelated topics (weather, politics, other software): decline in one line.

Sources, in order: (1) CONTEXT data; (2) knowledge-base excerpts - the main source for rules, norms, figures, technique, specs; (3) past_conversations, where "ПОДРОБНО:" marks the full text - retell it exactly. Never rely on your own recollection of training data. The app prints used excerpts verbatim under your reply: do not retell them, add no facts of your own. Use an excerpt only for the same subject (weapon, discipline, distance, category). If sources disagree, say which is which. A fact outside the sources, if the user insists, starts with "I think..." and is marked unverified.

CONTEXT: its "legend" line gives the column order of every table - read it first. A line "@date|..." starts a training, the lines under it are its shots. "…ещё N" = N rows omitted: never invent them. "device" = measured aim time/hold/sway: explains HOW a shot was fired. "weapon/ammo" is what the user shoots now: take it as given. "owner" says whose results these are: never mix people.
You can compute mean point of impact, group size, spread, averages, ring distribution; compare series, trainings, periods.

Blocks - the only fenced blocks allowed: at the very END of the reply, one of each kind, strict JSON (no comments, no trailing commas, raw numbers); confirm in one line before a block without retelling its JSON.
```chart only when it beats a sentence:
{"type":"line","title":"Result by shot","x":["1","2"],"series":[{"name":"Score","values":[10.3,9.8]}]}
types: line - one value per step; bar - categories; pie - shares, one positive series, up to 6 slices; table - exact values:
{"type":"table","title":"Series","columns":["Series","Total"],"rows":[["1","103.2"]]}
line/bar/pie: "x" and every "values" of equal length, up to 3 series. table: up to 4 columns and 8 rows, each row as long as "columns", one number format per column. Values only from the data; never pad a flat row of one number - say the data has no breakdown.
```exercise only when asked to create one: check "exercises_on_device" first, do not duplicate; target_face_code is one of rifle_10m, pistol_10m, rifle_50m, pistol_25m.
{"name":"Standing 40","target_face_code":"rifle_10m","total_shots":40,"series_size":10} or {"name":"Sighters + match","target_face_code":"pistol_10m","series":[{"name":"Sighters","time_limit_min":15,"counts":false},{"name":"Match","shot_count":40,"counts":true}]}
total_shots+series_size or series, never both; each series has exactly one of shot_count/time_limit_min.
```appearance only when asked to change the app look: only changed keys of CONTEXT "appearance" - blur 0..1, transparency 0..1 (higher = less colour), mode auto|manual|off, hue 0..360, sat 0..1.5 (mode manual). Greyer = higher transparency, lower sat. The user presses "Apply" and can undo.
```feedback only when asked: {"text":"..."} - the user's dictated wording (rephrased by meaning), anonymous, no names, trainings or personal data. You cannot send it: word it as a proposal, the user presses the button.
''';

  /// Простой промпт быстрого режима: только то, без чего нельзя, форматы
  /// блоков — по одному шаблону без повторения правил базы (было 1 707
  /// знаков, стало ~1.0 тыс.: у быстрого ответа и ответ короче, платить за
  /// тот же объём правил, что и в нормальном режиме, незачем).
  static const String fastPrompt = '''
You are the assistant of Nexus, a shooting-sports app. Answer fast and briefly.

Rules:
- Reply in the language the user writes in, 1-2 sentences: answer first, no preamble, no recap, no offers, no reasoning aloud. No clarifying questions. No insults.
- Facts (rules, norms, figures, technique) only from CONTEXT, the knowledge-base excerpts and past_conversations, never from memory; same subject only (weapon, discipline, distance, category). The app prints excerpts verbatim: do not retell them, add no facts of your own. Nothing there -> "no such data in the available materials".
- CONTEXT "legend" gives the column order; x,y are mm from the centre (x right, y up). "…ещё N" = rows omitted: never invent numbers.
- A vague question is about CONTEXT "source". App questions (Google Drive, messenger, finals, settings) are answered as well, 1-2 lines, from the APP GUIDE excerpt or what you know of the app. Unrelated topics (weather, politics): decline in one line.
- Only when explicitly asked, end with ONE block, strict JSON:
  ```chart {"type":"line|bar|pie","title":"..","x":["1","2"],"series":[{"name":"..","values":[1,2]}]}``` (x and values equal in length, up to 3 series) or {"type":"table","title":"..","columns":[".."],"rows":[[".."]]} (up to 4 columns, 8 rows);
  ```exercise {"name":"..","target_face_code":"rifle_10m|pistol_10m|rifle_50m|pistol_25m","total_shots":40,"series_size":10}``` (instead of total_shots/series_size a "series" list; check "exercises_on_device" first);
  ```feedback {"text":".."}``` (anonymous, the user sends it).
''';

  /// Правила режима — дописываются после базы (у быстрого — после его промпта).
  /// Сжаты 22.11: шесть пунктов «тихого рассуждения» были развёрнуты в
  /// полные предложения (1 225 знаков на каждое сообщение Normal), теперь
  /// те же требования — одной строкой на пункт.
  static String _profileRules(AiProfile p) => switch (p) {
        AiProfile.fast => '',
        AiProfile.normal => '''
MODE: NORMAL. Accuracy over brevity.
First a scratchpad (up to 120 words, plain lines, no headings): question type (numbers, rule, technique, planning); scope (training, series, period, weapon, discipline); evidence (CONTEXT columns and excerpt file names that apply, discard other weapons/disciplines/editions); recompute every sum, mean, difference and group size, check units and the target maximum; one alternative reading and why you drop it; conclusion and confidence.
Then a line with exactly ---ANSWER--- and only the answer after it. Small talk: answer directly, no scratchpad, no marker.
In the answer: conclusion first, then the key figures and how you got them (1-2 lines), for advice 1-3 concrete steps on the user's own data. Name the source of each rule or figure. Up to 6 sentences. Flag thin data (few shots, one training).
''',
        AiProfile.think => '''
MODE: THINK. CONTEXT ends with HELPER WORKING NOTES: drafts by colleagues - independent approaches plus a verifier's AGREED / DISPUTED. Treat them as a draft: check the decisive numbers against CONTEXT and the excerpts, fix mistakes silently, trust the data when they differ. Build on AGREED; for each DISPUTED point say plainly what differs and which reading the data supports. Do not retell the approaches or steps. Final answer: conclusion first, then the key figures, then 1-3 steps if useful. Lines marked NO DATA or (unverified) are gaps: name what is missing, do not guess. Up to 8 sentences.
''',
      };

  static const String _notesExtra = '''

Notes: only when explicitly asked to save a note, add a ```note block at the end {"topic":"Short topic","content":"Note text"} - only what the user dictated, no training/shot data and no earlier notes; confirm in one line without retelling the JSON.
''';

  /// Блок КОНТЕКСТ.
  ///
  /// Формат переписан 22.11 по отзыву владельца («сокращения для экономии
  /// токенов»): вместо JSON с ключами в КАЖДОЙ записи — таблицы через `|`
  /// и одна легенда с порядком колонок. На обычном контексте (60 тренировок
  /// истории, 600 выстрелов) JSON занимал ~60 тыс. знаков, таблицы — ~17
  /// тыс.: строка выстрела короче втрое. Порядок колонок фиксированный,
  /// поэтому формат остаётся предсказуемым, а модель читает его из легенды.
  String buildContextBlock(DateTime now) {
    final b = StringBuffer('КОНТЕКСТ\n');
    // Ярлык динамический: тренировка, открытая с экрана мишени, может быть
    // уже завершённой, и написать «идущая» — значит противоречить себе же
    // в поле status.
    final source = switch (scope) {
      AiScope.general => 'separate chat, outside a training',
      AiScope.session =>
        'training screen (${_statusRu(session?.status ?? SessionStatus.notStarted)})',
      AiScope.shot => 'note on a specific shot',
    };
    // Чьи это тренировки: свои или конкретного спортсмена (не смешивать).
    final owner = ownerLabel == null
        ? 'you (first person: "you/your results")'
        : 'athlete "$ownerLabel" - NOT the user, name this athlete';
    b.writeln('now=${_dt(now)} | source=$source | owner=$owner');
    // Легенда одна на весь блок: имена полей в каждой строке дороже, чем
    // один раз объяснить порядок колонок.
    b.writeln('legend: '
        '"@date|exercise|shots|total|average" starts a training, the lines '
        'under it are its shots "n|series|score|x|y"; "=above" = those shots '
        'are the open training above; "…ещё N" = N rows omitted (never invent '
        'them); x,y = mm from the target centre (x right, y up); '
        'a trailing "{...}" field = device data of that shot');

    final tint = BackdropTint.snapshot();
    b.writeln(
        'appearance=${tint.entries.map((e) => '${e.key}=${e.value}').join(' ')}');

    final f = face;
    if (f != null) {
      // Оружие/боеприпас отдельными полями, а не только внутри названия:
      // там они тонут в свободном тексте вместе с номером мишени, и модель
      // их пропускала — путала, из чего стреляет пользователь.
      b.writeln('target=${f.name} | weapon=${f.weaponRu} | ammo=${f.ammoRu} | '
          'distance=${_num(f.distanceM)} m | caliber=${_num(f.caliberMm)} mm | '
          'ring_radii_10_to_1_mm=${f.ringRadiiMm.map(_num).join(',')}');
    }

    if (existingExercises.isNotEmpty) {
      b.writeln('exercises_on_device=${existingExercises.take(80).map((e) => '${e.name}·${e.targetFaceCode}·${e.totalShots}').join(' | ')}');
    }

    final s = session;
    if (s != null) {
      b.writeln('training=exercise:${exercise?.label ?? exerciseNameOf(s)} | '
          'status:${_statusRu(s.status)} | started:${_dt(s.startedAt) ?? '-'} | '
          'finished:${_dt(s.finishedAt) ?? '-'} | '
          'duration:${_durationMin(s) ?? '-'} min | shots:${s.shots.length} | '
          'total:${_num(s.totalScore)} | '
          'series_size:${exercise?.seriesSize ?? '-'}');
      // Показатели из внешних приборов — время прицеливания, удержание,
      // скорость: связать результат с тем, КАК он получен, по одним
      // координатам невозможно.
      if (s.extra != null && s.extra!.isNotEmpty) {
        b.writeln('device=${jsonEncode(s.extra)}');
      }
      final open = _limitShots(s.shots);
      b.writeln('shots (open training, n|series|score|x|y|time):');
      for (final one in open) {
        b.writeln(_shotRow(one, withTime: true));
      }
      // Обрезанные строки помечаем явно: модель не должна досчитывать их
      // сама (отзыв 22.11 — «…ещё N» вместо молчаливого обрезания).
      if (open.length < s.shots.length) {
        b.writeln('…ещё ${s.shots.length - open.length}');
      }
    }

    final sh = shot;
    if (sh != null) {
      b.writeln('shot_in_question=${_shotRow(sh, withTime: true)}');
    }

    // Комментарии к выстрелам/сериям/сессии (если есть).
    if (comments.isNotEmpty) {
      b.writeln('comments (level|target|author|text|date):');
      for (final c in comments.take(40)) {
        b.writeln('${c['level']}|${c['shot_id'] ?? c['series_no'] ?? '-'}|'
            '${c['author_role']}|${c['text']}|${c['created_at']}');
      }
      if (comments.length > 40) b.writeln('…ещё ${comments.length - 40}');
    }

    if (pastSummaries.isNotEmpty) {
      // Кратко: дата и суть, без списка id тренировок — моделям это ничего
      // не скажет, а место в контексте займёт.
      b.writeln('past_conversations:');
      for (final p in pastSummaries) {
        b.writeln('${_dt(p.periodStart)}: ${p.summary}');
      }
    }

    // История: сводка по каждой тренировке плюс — пока хватает лимита —
    // сами выстрелы с координатами. Свежие тренировки получают координаты,
    // давние остаются сводкой; так вопрос про конкретное упражнение почти
    // всегда оказывается посчитан, а размер запроса остаётся предсказуемым.
    final history = allSessions.where((t) => t.shots.isNotEmpty).toList()
      ..sort((a, bb) {
        final ad = a.startedAt, bd = bb.startedAt;
        if (ad == null && bd == null) return 0;
        if (ad == null) return 1;
        if (bd == null) return -1;
        return bd.compareTo(ad); // свежие первыми
      });

    final listed = history.take(maxHistorySessions).toList();
    if (listed.isNotEmpty) {
      b.writeln('history:');
      var budget = maxHistoryShots;
      for (final t in listed) {
        b.write('@${_dt(t.startedAt) ?? '-'}|${exerciseNameOf(t)}|'
            '${t.shots.length}|${_num(t.totalScore)}|'
            '${_num(t.totalScore / t.shots.length)}');
        // Открытую тренировку не дублируем: её выстрелы уже выше.
        final isCurrent = s != null && t.id == s.id;
        if (isCurrent) {
          b.writeln('|=above');
        } else if (t.shots.length <= budget) {
          budget -= t.shots.length;
          b.writeln();
          for (final one in t.shots) {
            b.writeln(_shotRow(one));
          }
        } else {
          // Целиком не влезает — место кончилось. Дальше идут только
          // сводки, и мы честно помечаем, сколько выстрелов не отдано.
          b.writeln('|…ещё ${t.shots.length}');
        }
      }
      if (history.length > listed.length) {
        b.writeln('…ещё ${history.length - listed.length} training summaries');
      }
    }

    // Спортсмены тренера: по имени — чтобы не путать людей.
    if (athletes.isNotEmpty) {
      b.writeln('athletes (name|date|exercise|shots|total|average):');
      for (final a in athletes) {
        final list = a.sessions.where((t) => t.shots.isNotEmpty).toList()
          ..sort((x, y) => (y.startedAt ?? DateTime(0))
              .compareTo(x.startedAt ?? DateTime(0)));
        final take = list.take(15).toList();
        for (final t in take) {
          b.writeln('${a.name} (NOT the user)|${_dt(t.startedAt) ?? '-'}|'
              '${a.nameOf(t)}|${t.shots.length}|${_num(t.totalScore)}|'
              '${_num(t.totalScore / t.shots.length)}');
        }
        if (list.length > take.length) {
          b.writeln('${a.name}|…ещё ${list.length - take.length} training summaries');
        }
      }
    }

    return b.toString().trimRight();
  }

  /// Выстрелы открытой тренировки: если больше лимита — берём последние,
  /// свежие важнее.
  static List<Shot> _limitShots(List<Shot> shots) =>
      shots.length <= maxDetailedShots
          ? shots
          : shots.sublist(shots.length - maxDetailedShots);

  /// Одна строка выстрела: n|series|score|x|y[|time][|device].
  ///
  /// Время печатаем только у открытой тренировки (по нему видно темп
  /// серии): в истории это 600 строк по 9 знаков ради данных, которые
  /// почти не спрашивают.
  static String _shotRow(Shot s, {bool withTime = false}) => <String>[
        '${s.shotNumber}',
        '${s.seriesNo}',
        _num(s.score),
        _num(s.xMm),
        _num(s.yMm),
        if (withTime) _hm(s.time),
        // Показатели из внешних приборов — время прицеливания, удержание,
        // скорость. Ради них поле и заводилось: связать результат с тем,
        // КАК он получен, по одним координатам невозможно.
        if (s.extra != null && s.extra!.isNotEmpty) jsonEncode(s.extra),
      ].join('|');

  /// Число для таблицы: два знака после точки, у целых — без «.0» (экономит
  /// по 2 знака на каждое из трёх чисел в каждой строке выстрела).
  static String _num(double v) {
    final r = _round(v);
    return r == r.roundToDouble() ? r.toInt().toString() : r.toString();
  }

  /// Время выстрела в открытой тренировке: ч:мм:сс, без даты — дата
  /// тренировки уже есть строкой выше.
  static String _hm(DateTime d) {
    final l = d.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(l.hour)}:${two(l.minute)}:${two(l.second)}';
  }

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
