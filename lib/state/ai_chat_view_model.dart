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
      final chunks = await knowledge.search(trimmed);
      final books = KnowledgeService.asPromptBlock(chunks,
          tables: knowledge.settings.tables,
          catalog: await knowledge.catalogTitles());
      final history = <({String role, String text})>[
        for (final m in _recent())
          (role: m.fromUser ? 'user' : 'assistant', text: m.text),
      ];
      final askedAt = DateTime.now();
      var contextBlock = ctx.buildContextBlock(askedAt);
      if (service.settings.thinkingMode) {
        final notes = await _think(trimmed, contextBlock, history);
        if (notes.isNotEmpty) {
          contextBlock +=
              '\n\nРАБОЧИЕ ЗАМЕТКИ ПОМОЩНИКОВ (план и промежуточные расчёты — проверь их и используй для ответа, не пересказывай пользователю как есть):\n$notes';
        }
      }
      final reply = await service.ask(
        task: 'chat',
        image: image,
        systemPrompt: AiContext.systemPrompt(
          customInstructions: service.settings.customInstructions,
          coachMode: rawCtx.coachMode,
          baseOverride: service.settings.baseInstructionsOverride,
        ),
        contextBlock: contextBlock,
        history: history,
        booksExcerpt: books,
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
        summary: tr('В: {trimmed}\nО: {p}',
            {'trimmed': _gist(trimmed, 300), 'p': _gist(reply.text, 400)}),
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

  /// «Режим мышления» — несколько ИИ-помощников по очереди: первый
  /// составляет план из 2–4 шагов, второй решает каждый шаг по данным
  /// контекста, а итоговый ответ потом пишет обычный чатовый запрос,
  /// видя эти заметки. Любой сбой — тихо возвращаем пусто и отвечаем в
  /// быстром режиме (качество не должно упасть из-за лишнего шага).
  /// ponytail: шаги идут последовательно, не параллельно — бесплатные
  /// ключи не любят пачки запросов.
  Future<String> _think(String question, String contextBlock,
      List<({String role, String text})> history) async {
    try {
      final plan = await service.ask(
        systemPrompt:
            'Ты планировщик. Разбей вопрос пользователя про стрельбу на 2–4 коротких шага анализа (что посчитать или сравнить по данным КОНТЕКСТА). Ответ — только шаги, по одному в строке, без нумерации и пояснений.',
        contextBlock: contextBlock,
        history: [(role: 'user', text: question)],
      );
      final steps = plan.text
          .split('\n')
          .map((l) => l.replaceFirst(RegExp(r'^[\s\-\d.)•]+'), '').trim())
          .where((l) => l.length > 3)
          .take(4)
          .toList();
      if (steps.isEmpty) return '';
      final notes =
          StringBuffer('План:\n${steps.map((s) => '- $s').join('\n')}\n');
      for (final step in steps) {
        final r = await service.ask(
          systemPrompt:
              'Ты исполнитель одного шага анализа. Реши ТОЛЬКО указанный шаг по данным КОНТЕКСТА: приведи числа и короткий вывод (до 80 слов). Не выдумывай данных, которых нет.',
          contextBlock: '$contextBlock\n\nУЖЕ СДЕЛАНО:\n$notes',
          history: [(role: 'user', text: 'Вопрос: $question\nШаг: $step')],
        );
        notes.writeln('Шаг «$step»: ${r.text.trim()}');
      }
      return notes.toString();
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
    final full = 'Вопрос:\n$question\n\nОтвет:\n${reply.text}$chart';
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
