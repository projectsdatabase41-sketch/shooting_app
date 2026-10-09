import '../logic/friendly_error.dart';
import 'dart:async';

import 'package:flutter/foundation.dart';

import '../logic/ai_context.dart';
import '../models/ai_memory_summary.dart';
import '../services/ai_memory_service.dart';
import '../services/ai_service.dart';
import '../services/knowledge_service.dart';
import '../services/web_search_service.dart';
import '../i18n/i18n.dart';

class AiMessage {
  final bool fromUser;
  final String text;
  final Map<String, dynamic>? chart;
  final String? model;
  final bool isError;

  /// Рассуждения модели — показываются в чате отдельным свёрнутым
  /// блоком, чтобы не мешали читать сам ответ.
  final String? reasoning;

  /// Из каких источников базы знаний брались материалы для ответа.
  final List<String> sources;

  /// Предложенное упражнение, если модель его предложила (уже
  /// провалидировано белым списком в `AiService`).
  final Map<String, dynamic>? exercise;

  /// Упражнение из этого сообщения уже создано — кнопка "Создать"
  /// становится отметкой, а не предложением нажать ещё раз.
  final bool exerciseCreated;

  /// Предложенная заметка в дневник тренера, если модель её предложила
  /// (только в тренерском чате — см. `AiContext.coachMode`).
  final Map<String, dynamic>? note;
  final bool noteCreated;

  /// Предложенный отзыв об приложении (пункт 10 списка правок) — тот же
  /// принцип показа-на-подтверждение.
  final Map<String, dynamic>? feedback;
  final bool feedbackSent;

  /// Фото, приложенное к своему вопросу (только у `fromUser`) — показывается
  /// в пузыре как обычное вложение. Не сохраняется (весь разговор
  /// эфемерный, см. докстринг класса), уходит модели один раз, при отправке.
  final Uint8List? imageBytes;

  const AiMessage({
    required this.fromUser,
    required this.text,
    this.chart,
    this.model,
    this.isError = false,
    this.reasoning,
    this.sources = const [],
    this.exercise,
    this.exerciseCreated = false,
    this.note,
    this.noteCreated = false,
    this.feedback,
    this.feedbackSent = false,
    this.imageBytes,
  });

  AiMessage copyWith(
          {bool? exerciseCreated, bool? noteCreated, bool? feedbackSent}) =>
      AiMessage(
        fromUser: fromUser,
        text: text,
        chart: chart,
        model: model,
        isError: isError,
        reasoning: reasoning,
        sources: sources,
        exercise: exercise,
        exerciseCreated: exerciseCreated ?? this.exerciseCreated,
        note: note,
        noteCreated: noteCreated ?? this.noteCreated,
        feedback: feedback,
        feedbackSent: feedbackSent ?? this.feedbackSent,
      );
}

/// Состояние разговора с ассистентом.
///
/// Живёт СТОЛЬКО ЖЕ, СКОЛЬКО ЗАПУЩЕННОЕ ПРИЛОЖЕНИЕ (решение
/// пользователя: «оставить память внутри сессии, чтобы можно было
/// закрыть чат, посмотреть что-то где-то и продолжить диалог; удалять
/// только при закрытии приложения»). Раньше объект создавался прямо на
/// экране чата и умирал вместе с ним — вышел посмотреть тренировку,
/// вернулся, а разговор пустой.
///
/// В базу переписка по-прежнему не пишется: закрыл приложение —
/// разговор исчез. Модели уходит только хвост из [memoryTurns] реплик,
/// сколько бы их ни накопилось: бесплатные модели на длинном контексте
/// работают заметно хуже.
class AiChatViewModel extends ChangeNotifier {
  final AiService service;
  final KnowledgeService knowledge;

  /// Записи прошлых разговоров (пункт 10 списка правок) — читает и
  /// пишет `ai_conversation_summaries` в личной базе спортсмена: одна
  /// строка на КАЖДЫЙ обмен вопрос-ответ, находится по ключевым словам
  /// (`search`), а не слепым "последние N". Молчит сама по себе, если
  /// облако не подключено — методы `search`/`append` в этом случае
  /// просто ничего не делают, а не бросают ошибку.
  final AiMemoryService memory;

  /// Откуда брать контекст на момент отправки.
  ///
  /// Не поле-значение, а функция, и меняется при открытии экрана:
  /// объект теперь один на всё приложение, а вопрос может прийти и из
  /// общего чата, и с экрана идущей тренировки, и из заметки к
  /// выстрелу — источник каждый раз свой.
  AiContext Function() contextBuilder;

  AiChatViewModel({
    required this.service,
    required this.knowledge,
    required this.memory,
    required this.contextBuilder,
  });

  /// Переключает источник вопросов, не трогая историю разговора.
  void useContext(AiContext Function() builder) {
    contextBuilder = builder;
  }

  /// Сколько последних реплик уходит модели. Дальше — обрезаем.
  static const int memoryTurns = 8;

  final List<AiMessage> messages = [];
  bool _busy = false;
  bool get busy => _busy;

  /// Что ассистент делает сейчас (русский ключ перевода) — для анимации в чате.
  String _phase = /*tr*/ 'Ищу информацию';
  String get phase => _phase;

  /// Номер подхода в режиме Think («2/3») — дописывается к подписи шага.
  String _phaseProgress = '';
  String get phaseProgress => _phaseProgress;
  void _setPhase(String p, {String progress = ''}) {
    if (_phase == p && _phaseProgress == progress) return;
    _phase = p;
    _phaseProgress = progress;
    notifyListeners();
  }

  /// Все графики из ответов. Осталось для возможных сводок; отдельной
  /// панели графиков в чате больше нет — они рисуются в сообщениях.
  List<AiMessage> get chartMessages =>
      messages.where((m) => m.chart != null).toList();

  /// Удаляет сообщение и всё, что было после него.
  ///
  /// Именно «и всё после», а не одно сообщение: ответ без вопроса (или
  /// вопрос без ответа) превращает переписку в бессмыслицу, а модель
  /// получает рваную историю и начинает отвечать невпопад.
  void removeFrom(int index) {
    if (index < 0 || index >= messages.length) return;
    messages.removeRange(index, messages.length);
    notifyListeners();
  }

  /// Спрашивает заново, забыв прежнюю попытку.
  ///
  /// Сообщение и всё после него удаляются ДО отправки — поэтому в
  /// историю для модели прежний вопрос уже не попадает, и она не
  /// отвечает «как я писал выше». Ровно этого просил пользователь.
  Future<void> retryFrom(int index) async {
    if (index < 0 || index >= messages.length) return;
    final message = messages[index];
    if (!message.fromUser) return;
    final text = message.text;
    removeFrom(index);
    await send(text);
  }

  /// Как [retryFrom], но с ИЗМЕНЁННЫМ текстом вопроса (пункт 6 списка
  /// правок — редактирование, а не только удаление и переспрос заново).
  Future<void> editAndRetry(int index, String newText) async {
    if (index < 0 || index >= messages.length) return;
    if (!messages[index].fromUser) return;
    removeFrom(index);
    await send(newText);
  }

  /// [image] — фото к вопросу (кнопка-скрепка в чате, только когда активна
  /// модель со зрением, см. `_ModelPickerButton`/`AiSettings.chatModelChoice`).
  Future<void> send(String text, {Uint8List? image}) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty || _busy) return;

    messages.add(AiMessage(fromUser: true, text: trimmed, imageBytes: image));
    _busy = true;
    // Режим чата выбирается кнопками Fast / Normal / Think. Think начинается
    // с анализа вопроса, остальные — сразу с поиска.
    final mode = service.settings.chatMode;
    _phase = mode == 'think' ? /*tr*/ 'Анализирую' : /*tr*/ 'Ищу информацию';
    notifyListeners();

    try {
      final rawCtx = contextBuilder();
      // По ключевым словам вопроса, а не слепые "последние 20" —
      // решение пользователя (пункт 10, уточнение того же дня):
      // старая версия тянула недавние сводки независимо от темы.
      var pastSummaries = await memory.search(trimmed);
      // Просьба вспомнить — подмешиваем ПОЛНЫЕ тексты подходящих обменов
      // (до 3000 символов каждый) вместо кратких пересказов тех же записей.
      final recalled = await memory.recallDetails(trimmed);
      if (recalled.isNotEmpty) {
        final ids = {for (final r in recalled) r.id};
        pastSummaries = [
          for (final r in recalled)
            AiMemorySummary(
              id: r.id,
              periodStart: r.periodStart,
              periodEnd: r.periodEnd,
              summary: 'ПОДРОБНО: ${_gist(r.detail!, 3000)}',
              trainingPackageIds: r.trainingPackageIds,
            ),
          ...pastSummaries.where((s) => !ids.contains(s.id)),
        ];
      }
      final ctx = pastSummaries.isEmpty
          ? rawCtx
          : rawCtx.withPastSummaries(pastSummaries);
      _setPhase(/*tr*/ 'Ищу информацию');
      var chunks = await knowledge.search(trimmed);
      // Normal и Think: если поиск по словам вопроса нашёл мало (короткие
      // термины вроде «ISSF», другие словоформы), модель подсказывает
      // синонимы, и поиск повторяется с ними. Fast этого не делает — он
      // должен отвечать сразу.
      if (mode != 'fast' &&
          chunks.length < 3 &&
          trimmed.length >= 12 &&
          !KnowledgeService.isSmallTalk(trimmed)) {
        final terms = await _expandQuery(trimmed);
        if (terms.isNotEmpty) {
          final more = await knowledge.search(trimmed, extraTerms: terms);
          final seen = {for (final c in chunks) c.text};
          chunks = [...chunks, ...more.where((c) => !seen.contains(c.text))];
        }
      }
      final books = KnowledgeService.asPromptBlock(chunks,
          tables: knowledge.settings.tables,
          catalog: mode == 'fast' ? const [] : await knowledge.catalogTitles());
      final history = <({String role, String text})>[
        for (final m in _recent())
          (role: m.fromUser ? 'user' : 'assistant', text: m.text),
      ];
      final askedAt = DateTime.now();
      var contextBlock = ctx.buildContextBlock(askedAt);
      // Think нужен не на болтовню и не на совсем короткие вопросы.
      var notes = '';
      if (mode == 'think' &&
          !KnowledgeService.isSmallTalk(trimmed) &&
          trimmed.length >= 12) {
        notes = await _think(trimmed, contextBlock, history, books);
        if (notes.isNotEmpty) {
          contextBlock +=
              '\n\nHELPER WORKING NOTES (a plan, step results and verifier corrections — check them and use them for the answer, do not retell them to the user as is):\n$notes';
        }
      }
      _setPhase(/*tr*/ 'Формулирую ответ');
      final reply = await service.ask(
        task: 'chat',
        image: image,
        systemPrompt: AiContext.systemPrompt(
          customInstructions: service.settings.customInstructions,
          coachMode: rawCtx.coachMode,
          baseOverride: service.settings.baseInstructionsOverride,
          profile: notes.isNotEmpty
              ? AiProfile.think
              : mode == 'fast'
                  ? AiProfile.fast
                  : AiProfile.normal,
        ),
        contextBlock: contextBlock,
        history: history,
        booksExcerpt: books,
        rotateKeys: mode == 'think',
      );
      messages.add(AiMessage(
        fromUser: false,
        text: reply.text,
        chart: reply.chart,
        model: reply.model,
        reasoning: reply.reasoning,
        sources: {for (final c in chunks) c.source}.toList(),
        exercise: reply.exercise,
        note: reply.note,
        feedback: reply.feedback,
      ));
      // Пишем КАЖДЫЙ обмен как есть, без лишнего вызова модели на
      // сжатие (решение пользователя, пункт 10: "лучше в раг каждый
      // запрос записывает") — вопрос уже короткий сам по себе, а
      // дополнительный запрос к ИИ только тратил бы и без того
      // ограниченную квоту бесплатных моделей на каждое сообщение.
      unawaited(memory.append(AiMemorySummary(
        periodStart: askedAt,
        periodEnd: DateTime.now(),
        // Краткая запись — вопрос и суть ответа, для понимания хода диалога.
        summary: 'Q: ${_gist(trimmed, 300)}\nA: ${_gist(reply.text, 400)}',
        // Развёрнутая — обмен целиком, чтобы потом вспомнить подробности.
        detail: _fullRecord(trimmed, reply),
        trainingPackageIds:
            rawCtx.session != null ? [rawCtx.session!.id] : const [],
      )));
    } catch (e) {
      messages.add(
          AiMessage(fromUser: false, text: friendlyError(e), isError: true));
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  /// Подсказка поиску: синонимы и короткие термины, которых нет среди
  /// «длинных» слов вопроса. Сбой — пусто (останется обычный поиск).
  Future<List<String>> _expandQuery(String question) async {
    try {
      final r = await service.ask(
        systemPrompt:
            'You prepare search terms for a shooting-sports knowledge base written mostly in Russian. From the question output 4-8 single words (stems, synonyms, abbreviations such as ISSF, numbers with units such as 10м) that would appear in a relevant passage. Output the words separated by commas and nothing else.',
        contextBlock: '',
        history: [(role: 'user', text: question)],
        rotateKeys: true,
      );
      return r.text
          .split(RegExp(r'[,;\n]'))
          .map((w) => w.trim())
          .where((w) => w.isNotEmpty && w.length <= 24)
          .take(8)
          .toList();
    } catch (_) {
      return const [];
    }
  }

  /// Режим Think — несколько помощников и несколько независимых подходов к
  /// одному вопросу:
  /// 1. планировщик предлагает 2–3 РАЗНЫХ подхода (например, по выстрелам
  ///    тренировки, по истории, по правилам из базы);
  /// 2. решатель отдельно проходит каждый подход до результата;
  /// 3. проверяющий сводит результаты: где подходы сошлись, где нет, сверяет
  ///    числа с данными и выдаёт итоговые заметки.
  /// Итоговый ответ потом пишет обычный чатовый запрос, видя эти заметки.
  /// Помощники видят и данные пользователя, и найденные куски базы знаний.
  /// Сбой планировщика или решателя — тихо возвращаем пусто (ответит как
  /// Normal); сбой проверяющего — остаются результаты подходов.
  /// ponytail: подходы идут последовательно, не параллельно — бесплатные
  /// ключи не любят пачки запросов.
  Future<String> _think(String question, String contextBlock,
      List<({String role, String text})> history, String? books) async {
    try {
      _setPhase(/*tr*/ 'Анализирую');
      final plan = await service.ask(
        systemPrompt:
            'You are a planner. Propose 1-3 genuinely DIFFERENT approaches to answer the user question about shooting, each using a different angle or different data (for example: the shots of the open training; the history of past trainings; a rule or norm from the knowledge-base excerpts; a direct calculation versus a comparison). A simple lookup needs ONE approach. Each approach is one line: a short name, a colon, and what exactly to compute or check. No numbering, no explanations. Write in the language of the question.',
        contextBlock: contextBlock,
        booksExcerpt: books,
        history: [(role: 'user', text: question)],
        rotateKeys: true,
      );
      final approaches = plan.text
          .split('\n')
          .map((l) => l.replaceFirst(RegExp(r'^[\s\-\d.)•]+'), '').trim())
          .where((l) => l.length > 3)
          .take(3)
          .toList();
      if (approaches.isEmpty) return '';

      final results = <String>[];
      for (final (i, approach) in approaches.indexed) {
        _setPhase(/*tr*/ 'Думаю', progress: '${i + 1}/${approaches.length}');
        final r = await service.ask(
          systemPrompt:
              'You solve the user question using ONLY the given approach, independently of any other approach. Use the CONTEXT data and the excerpts; give the numbers with the calculation in one or two lines, then the conclusion in one sentence and your confidence (high / medium / low). If the data for the approach is missing, answer exactly "NO DATA: <what is missing>". Never invent data. Up to 120 words. Write in the language of the question.',
          contextBlock: contextBlock,
          booksExcerpt: books,
          history: [(role: 'user', text: 'Question: $question\nApproach: $approach')],
          rotateKeys: true,
        );
        results.add('Approach ${i + 1} "$approach": ${r.text.trim()}');
      }
      final draft = results.join('\n');
      if (approaches.length == 1) return draft;

      _setPhase(/*tr*/ 'Проверяю');
      try {
        final v = await service.ask(
          systemPrompt:
              'You are a strict verifier and judge. You get results of several independent approaches to one question. (1) Check every number against the CONTEXT data and recompute sums, means and differences. (2) Compare the approaches: say where they AGREE and where they CONTRADICT, and which one is more reliable and why. (3) Output the corrected approach results unchanged where right, then two lines: "AGREED: <what all reliable approaches support>" and "DISPUTED: <what differs or is unverified, or none>". Mark unverifiable statements with "(unverified)". No new analysis. Write in the language of the question.',
          contextBlock: '$contextBlock\n\nAPPROACH RESULTS:\n$draft',
          booksExcerpt: books,
          history: [(role: 'user', text: 'Question: $question')],
          rotateKeys: true,
        );
        if (v.text.trim().length > 20) return v.text.trim();
      } catch (_) {}
      return draft;
    } catch (_) {
      return '';
    }
  }

  /// Вопрос идёт не в чат-модель, а в поиск Google (Gemini с Google
  /// Search): ответ приходит прямо в разговор, источники — списком под ним.
  Future<void> searchWeb(String query) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty || _busy) return;
    messages.add(AiMessage(fromUser: true, text: '🔎 $trimmed'));
    _busy = true;
    notifyListeners();
    try {
      final r = await WebSearchService(service.settings).search(trimmed);
      final links = r.sources.isEmpty
          ? ''
          : '\n\n${tr('Источники:')}\n${r.sources.take(6).map((s) => '• ${s.title} — ${s.url}').join('\n')}';
      messages.add(AiMessage(
          fromUser: false,
          text: '${r.text}$links',
          model: tr('Поиск в интернете')));
    } catch (e) {
      messages.add(
          AiMessage(fromUser: false, text: friendlyError(e), isError: true));
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  /// Обрезает ответ до короткой выдержки для памяти — полный текст там
  /// не нужен, только чтобы потом узнать, о чём был разговор.
  static String _gist(String text, [int max = 200]) {
    final oneLine = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    return oneLine.length <= max ? oneLine : '${oneLine.substring(0, max)}…';
  }

  /// Обмен целиком (вопрос + ответ + пометка о графике) — «развёрнутая»
  /// память; предел защищает базу от огромных ответов.
  static String _fullRecord(String question, AiReply reply) {
    final chart = reply.chart == null
        ? ''
        : '\n[график: ${reply.chart!['title'] ?? reply.chart!['type'] ?? ''}]';
    final full = 'Question:\n$question\n\nAnswer:\n${reply.text}$chart';
    return full.length <= 12000 ? full : '${full.substring(0, 12000)}…';
  }

  /// Отмечает, что упражнение из сообщения [index] уже создано —
  /// нажатая кнопка "Создать" не должна заводить дубликат при
  /// повторном нажатии или перерисовке.
  void markExerciseCreated(int index) {
    if (index < 0 || index >= messages.length) return;
    messages[index] = messages[index].copyWith(exerciseCreated: true);
    notifyListeners();
  }

  /// Отмечает, что заметка из сообщения [index] уже сохранена в дневник.
  void markNoteCreated(int index) {
    if (index < 0 || index >= messages.length) return;
    messages[index] = messages[index].copyWith(noteCreated: true);
    notifyListeners();
  }

  /// Отмечает, что отзыв из сообщения [index] уже отправлен.
  void markFeedbackSent(int index) {
    if (index < 0 || index >= messages.length) return;
    messages[index] = messages[index].copyWith(feedbackSent: true);
    notifyListeners();
  }

  /// Последние реплики без ошибок — ошибки в историю модели не отдаём,
  /// иначе она начинает их обсуждать вместо стрельбы.
  List<AiMessage> _recent() {
    final clean = messages.where((m) => !m.isError).toList();
    return clean.length <= memoryTurns
        ? clean
        : clean.sublist(clean.length - memoryTurns);
  }

  void clear() {
    messages.clear();
    notifyListeners();
  }
}
