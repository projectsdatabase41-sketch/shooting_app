import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../logic/ai_context.dart';
import '../models/exercise.dart';
import '../models/series_spec.dart';
import '../models/shot.dart';
import '../models/target_face.dart';
import '../models/training_session.dart';
import '../state/ai_chat_view_model.dart';
import '../state/app_data_store.dart';
import '../widgets/ai_chart_view.dart';
import '../widgets/empty_state.dart';
import '../widgets/raised_3d_button.dart';
import '../widgets/weapon_icon.dart';

/// Чат с ассистентом по результатам стрельбы.
///
/// Одна лента: графики и таблицы рисуются прямо в сообщениях. Отдельная
/// страница «Графики» была, но её убрали — её горизонтальный свайп
/// конфликтовал с листанием рабочего стола, а содержимое дублировало
/// то, что уже видно в переписке.
///
/// Экран открывается из трёх мест, и от места зависит `scope`, который
/// уходит модели: из настроек — общий разговор, с экрана мишени — вопрос
/// по идущей тренировке, из заметки к выстрелу — вопрос по выстрелу.
class AiChatScreen extends StatelessWidget {
  final AiScope scope;
  final TrainingSession? session;
  final Exercise? exercise;
  final TargetFace? face;
  final Shot? shot;

  /// Встроен ли чат в другой экран (страница рабочего стола).
  ///
  /// Тогда своей шапки у него быть не должно: заголовок и кнопки уже
  /// есть у рабочего стола, а вторая полоса сверху съедала бы место и
  /// путала — какая из них к чему относится.
  final bool embedded;

  const AiChatScreen({
    super.key,
    this.scope = AiScope.general,
    this.session,
    this.exercise,
    this.face,
    this.shot,
    this.embedded = false,
  });

  @override
  Widget build(BuildContext context) {
    final store = context.read<AppDataStore>();
    // Модель разговора живёт в корне приложения и переживает закрытие
    // экрана — здесь она не создаётся, а только берётся и настраивается
    // на текущий источник вопроса.
    final vm = context.read<AiChatViewModel>();
    vm.useContext(() => AiContext(
          scope: scope,
          session: session,
          exercise: exercise,
          face: face,
          shot: shot,
          allSessions: store.sessions,
          // Код в подпись обязательно: пользователь спрашивает
          // «а по упражнению 234», и это именно код, а не название.
          // Без него модель просто не находит, о чём речь.
          exerciseNameOf: (s) => store.exerciseFor(s)?.label ?? 'без упражнения',
        ));
    return _AiChatBody(embedded: embedded);
  }
}

class _AiChatBody extends StatefulWidget {
  final bool embedded;

  const _AiChatBody({this.embedded = false});

  @override
  State<_AiChatBody> createState() => _AiChatBodyState();
}

class _AiChatBodyState extends State<_AiChatBody> {
  final _input = TextEditingController();
  final _scroll = ScrollController();

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _send(AiChatViewModel vm) {
    final text = _input.text;
    if (text.trim().isEmpty) return;
    _input.clear();
    vm.send(text).then((_) => _scrollToEnd());
    _scrollToEnd();
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final vm = context.watch<AiChatViewModel>();

    // Отдельной страницы «Графики» больше нет.
    //
    // Внутренний PageView перехватывал горизонтальный свайп, и с чата
    // нельзя было пролистать дальше по рабочему столу — палец уходил в
    // переключение вкладок. А сами графики и так рисуются прямо в
    // сообщениях, так что вторая страница только дублировала их.
    final body = Column(
      children: [
        Expanded(child: _buildChat(vm)),
        _buildInput(vm),
      ],
    );

    if (widget.embedded) return body;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Ассистент'),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_sweep_outlined),
            tooltip: 'Очистить разговор',
            onPressed: vm.messages.isEmpty ? null : vm.clear,
          ),
        ],
      ),
      body: body,
    );
  }

  Widget _buildChat(AiChatViewModel vm) {
    if (vm.messages.isEmpty) {
      return const EmptyState(
        icon: Icons.forum_outlined,
        text: 'Спросите про свои результаты — например «где кучнее, в первой серии или в последней?»',
      );
    }
    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
      itemCount: vm.messages.length + (vm.busy ? 1 : 0),
      itemBuilder: (context, i) {
        if (i >= vm.messages.length) return const _TypingBubble();
        return _Bubble(
          message: vm.messages[i],
          // Удалить свой вопрос вместе с ответом и спросить заново.
          // Важно, что модель о нём ЗАБЫВАЕТ: иначе на повтор она
          // отвечает «как я уже писал выше» — переспрашивать смысла
          // не было бы.
          onRetry: vm.messages[i].fromUser && !vm.busy ? () => vm.retryFrom(i) : null,
          onDelete: vm.busy ? null : () => vm.removeFrom(i),
          onCreateExercise: (vm.messages[i].exercise != null && !vm.messages[i].exerciseCreated)
              ? () => _createExercise(context, vm, i)
              : null,
        );
      },
    );
  }

  /// Создаёт упражнение из блока, который предложил ассистент.
  ///
  /// Спецификация уже провалидирована белым списком в `AiService`
  /// (`_isValidExercise`) — здесь только раскладываем провалидированный
  /// JSON в вызов `store.createExercise`, который используется и
  /// обычным экраном создания упражнения.
  void _createExercise(BuildContext context, AiChatViewModel vm, int index) {
    final spec = vm.messages[index].exercise;
    if (spec == null) return;
    final store = context.read<AppDataStore>();

    final rawSeries = spec['series'];
    final series = rawSeries is List
        ? [
            for (final s in rawSeries.cast<Map>())
              SeriesSpec(
                name: '${s['name']}',
                shotCount: (s['shot_count'] as num?)?.toInt(),
                timeLimit: s['time_limit_min'] == null
                    ? null
                    : Duration(minutes: (s['time_limit_min'] as num).toInt()),
                counts: s['counts'] != false,
              ),
          ]
        : const <SeriesSpec>[];

    final gender = ExerciseGender.values.firstWhere(
      (g) => g.name == '${spec['gender'] ?? 'mixed'}',
      orElse: () => ExerciseGender.mixed,
    );

    final ex = store.createExercise(
      name: '${spec['name']}',
      targetFaceCode: '${spec['target_face_code']}',
      // У упражнения со своими сериями total_shots/series_size не несут
      // смысла — раскладка идёт по `series` (см. 7.2 ТЗ), но колонки в
      // базе NOT NULL, так что пишем сумму выстрелов серий и 1.
      totalShots: series.isNotEmpty
          ? series.fold<int>(0, (a, s) => a + (s.shotCount ?? 0))
          : (spec['total_shots'] as num).toInt(),
      seriesSize: series.isNotEmpty ? 1 : (spec['series_size'] as num).toInt(),
      gender: gender,
      series: series,
    );

    vm.markExerciseCreated(index);
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text('Упражнение «${ex.name}» создано')));
  }

  Widget _buildInput(AiChatViewModel vm) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: TextField(
                controller: _input,
                minLines: 1,
                maxLines: 4,
                textInputAction: TextInputAction.send,
                decoration: const InputDecoration(hintText: 'Вопрос по стрельбе'),
                onSubmitted: (_) => _send(vm),
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filled(
              onPressed: vm.busy ? null : () => _send(vm),
              icon: const Icon(Icons.send),
            ),
          ],
        ),
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  final AiMessage message;
  final VoidCallback? onRetry;
  final VoidCallback? onDelete;

  /// `null`, если в сообщении нет предложенного упражнения или оно уже
  /// создано — тогда карточка показывает отметку без кнопки.
  final VoidCallback? onCreateExercise;

  const _Bubble({required this.message, this.onRetry, this.onDelete, this.onCreateExercise});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final mine = message.fromUser;
    final bg = message.isError
        ? cs.errorContainer
        : (mine ? cs.primaryContainer : cs.surfaceContainerHigh);
    final fg = message.isError
        ? cs.onErrorContainer
        : (mine ? cs.onPrimaryContainer : cs.onSurface);

    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: GestureDetector(
        onLongPress: (onRetry == null && onDelete == null)
            ? null
            : () => _showActions(context),
        child: Container(
        constraints: const BoxConstraints(maxWidth: 560),
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(14)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (message.reasoning != null) ...[
              _ReasoningBlock(text: message.reasoning!, color: fg),
              const SizedBox(height: 8),
            ],
            SelectableText(message.text, style: theme.textTheme.bodyMedium?.copyWith(color: fg)),
            if (message.chart != null) ...[
              const SizedBox(height: 8),
              AiChartView(spec: message.chart!),
            ],
            if (message.exercise != null) ...[
              const SizedBox(height: 8),
              _ExerciseProposalCard(
                spec: message.exercise!,
                created: message.exerciseCreated,
                onCreate: onCreateExercise,
              ),
            ],
            if (message.sources.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                'Источники: ${message.sources.join(', ')}',
                style: theme.textTheme.labelSmall?.copyWith(color: fg.withValues(alpha: 0.75)),
              ),
            ],
            if (message.model != null) ...[
              const SizedBox(height: 4),
              Text(
                message.model!,
                style: theme.textTheme.labelSmall?.copyWith(color: fg.withValues(alpha: 0.6)),
              ),
            ],
          ],
        ),
        ),
      ),
    );
  }

  void _showActions(BuildContext context) {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (onRetry != null)
              ListTile(
                leading: const Icon(Icons.refresh),
                title: const Text('Спросить заново'),
                subtitle: const Text('Ассистент забудет прежний вопрос и ответ'),
                onTap: () {
                  Navigator.of(ctx).pop();
                  onRetry!();
                },
              ),
            if (onDelete != null)
              ListTile(
                leading: const Icon(Icons.delete_outline),
                title: const Text('Удалить'),
                onTap: () {
                  Navigator.of(ctx).pop();
                  onDelete!();
                },
              ),
          ],
        ),
      ),
    );
  }
}

/// Карточка предложенного ассистентом упражнения — показ результата на
/// подтверждение, а не тихое создание: пользователь видит, что именно
/// заведётся, прежде чем это попадёт в список упражнений.
class _ExerciseProposalCard extends StatelessWidget {
  final Map<String, dynamic> spec;
  final bool created;
  final VoidCallback? onCreate;

  const _ExerciseProposalCard({required this.spec, required this.created, required this.onCreate});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final face = TargetFace.byCode('${spec['target_face_code']}');
    final rawSeries = spec['series'];
    final seriesList = rawSeries is List ? rawSeries.cast<Map>() : null;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: cs.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(Icons.assignment_add, size: 18, color: cs.primary),
              const SizedBox(width: 6),
              Expanded(
                child: Text('${spec['name']}', style: theme.textTheme.titleSmall),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              WeaponIcon(face: face, size: 14, color: theme.textTheme.bodySmall?.color),
              const SizedBox(width: 6),
              Text(face.name, style: theme.textTheme.bodySmall),
            ],
          ),
          if (seriesList != null)
            for (final s in seriesList)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  '· ${s['name']}'
                  '${s['shot_count'] != null ? ' — ${s['shot_count']} выстр.' : ''}'
                  '${s['time_limit_min'] != null ? ' — ${s['time_limit_min']} мин' : ''}'
                  '${s['counts'] == false ? ' (без зачёта)' : ''}',
                  style: theme.textTheme.bodySmall,
                ),
              )
          else
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                '${spec['total_shots']} выстрелов по ${spec['series_size']}',
                style: theme.textTheme.bodySmall,
              ),
            ),
          const SizedBox(height: 10),
          if (created)
            Row(
              children: [
                Icon(Icons.check_circle, size: 18, color: cs.primary),
                const SizedBox(width: 6),
                Text('Создано', style: theme.textTheme.bodySmall?.copyWith(color: cs.primary)),
              ],
            )
          else
            Raised3DButton(
              dense: true,
              icon: Icons.add,
              label: 'Создать упражнение',
              baseColor: cs.primary,
              onTap: onCreate,
            ),
        ],
      ),
    );
  }
}

class _TypingBubble extends StatelessWidget {
  const _TypingBubble();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: cs.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(14),
        ),
        child: SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(strokeWidth: 2, color: cs.onSurfaceVariant),
        ),
      ),
    );
  }
}

/// Свёрнутый блок «Завершено размышление».
///
/// Рассуждения модели не выбрасываются, а прячутся под раскрывающийся
/// заголовок: сам ответ остаётся читаемым, но при желании видно, на чём
/// модель его построила. Именно так эту проблему решают взрослые чаты —
/// и это честнее, чем молча резать текст.
class _ReasoningBlock extends StatefulWidget {
  final String text;
  final Color color;

  const _ReasoningBlock({required this.text, required this.color});

  @override
  State<_ReasoningBlock> createState() => _ReasoningBlockState();
}

class _ReasoningBlockState extends State<_ReasoningBlock> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = widget.color.withValues(alpha: 0.7);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        InkWell(
          onTap: () => setState(() => _open = !_open),
          borderRadius: BorderRadius.circular(6),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.lightbulb_outline, size: 15, color: muted),
                const SizedBox(width: 6),
                Text(
                  'Завершено размышление',
                  style: theme.textTheme.labelMedium?.copyWith(color: muted),
                ),
                Icon(_open ? Icons.expand_more : Icons.chevron_right, size: 18, color: muted),
              ],
            ),
          ),
        ),
        if (_open) ...[
          const SizedBox(height: 6),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              border: Border(left: BorderSide(color: muted, width: 2)),
            ),
            child: SelectableText(
              widget.text,
              style: theme.textTheme.bodySmall?.copyWith(color: muted, height: 1.35),
            ),
          ),
        ],
      ],
    );
  }
}
