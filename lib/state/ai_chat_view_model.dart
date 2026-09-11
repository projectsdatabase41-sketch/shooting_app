import 'dart:async';

import 'package:flutter/foundation.dart';

import '../logic/ai_context.dart';
import '../models/ai_memory_summary.dart';
import '../services/ai_memory_service.dart';
import '../services/ai_service.dart';
import '../services/knowledge_service.dart';

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
  });

  AiMessage copyWith({bool? exerciseCreated}) => AiMessage(
        fromUser: fromUser,
        text: text,
        chart: chart,
        model: model,
        isError: isError,
        reasoning: reasoning,
        sources: sources,
        exercise: exercise,
        exerciseCreated: exerciseCreated ?? this.exerciseCreated,
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

  Future<void> send(String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty || _busy) return;

    messages.add(AiMessage(fromUser: true, text: trimmed));
    _busy = true;
    notifyListeners();

    try {
      final rawCtx = contextBuilder();
      // По ключевым словам вопроса, а не слепые "последние 20" —
      // решение пользователя (пункт 10, уточнение того же дня):
      // старая версия тянула недавние сводки независимо от темы.
      final pastSummaries = await memory.search(trimmed);
      final ctx = pastSummaries.isEmpty ? rawCtx : rawCtx.withPastSummaries(pastSummaries);
      final chunks = await knowledge.search(trimmed);
      final books = KnowledgeService.asPromptBlock(chunks);
      final history = <({String role, String text})>[
        for (final m in _recent()) (role: m.fromUser ? 'user' : 'assistant', text: m.text),
      ];
      final askedAt = DateTime.now();
      final reply = await service.ask(
        systemPrompt: AiContext.systemPrompt(customInstructions: service.settings.customInstructions),
        contextBlock: ctx.buildContextBlock(askedAt),
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
      ));
      // Пишем КАЖДЫЙ обмен как есть, без лишнего вызова модели на
      // сжатие (решение пользователя, пункт 10: "лучше в раг каждый
      // запрос записывает") — вопрос уже короткий сам по себе, а
      // дополнительный запрос к ИИ только тратил бы и без того
      // ограниченную квоту бесплатных моделей на каждое сообщение.
      unawaited(memory.append(AiMemorySummary(
        periodStart: askedAt,
        periodEnd: DateTime.now(),
        summary: 'В: $trimmed\nО: ${_gist(reply.text)}',
        trainingPackageIds: rawCtx.session != null ? [rawCtx.session!.id] : const [],
      )));
    } catch (e) {
      messages.add(AiMessage(fromUser: false, text: '$e', isError: true));
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  /// Обрезает ответ до короткой выдержки для памяти — полный текст там
  /// не нужен, только чтобы потом узнать, о чём был разговор.
  static String _gist(String text) {
    final oneLine = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    return oneLine.length <= 200 ? oneLine : '${oneLine.substring(0, 200)}…';
  }

  /// Отмечает, что упражнение из сообщения [index] уже создано —
  /// нажатая кнопка "Создать" не должна заводить дубликат при
  /// повторном нажатии или перерисовке.
  void markExerciseCreated(int index) {
    if (index < 0 || index >= messages.length) return;
    messages[index] = messages[index].copyWith(exerciseCreated: true);
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
