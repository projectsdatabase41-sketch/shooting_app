import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';
import '../models/comment.dart';
import '../services/comments_repository.dart';
import '../state/app_data_store.dart';
import '../state/target_view_model.dart';

/// Лента комментариев — НЕ перезаписываемое поле, а лента записей с
/// автором и временем (раздел 7 ТЗ, часть C.3 логики-спека). Доступна на
/// всех уровнях независимо от роли/статуса тренировки — в отличие от
/// canEdit (C.2).
///
/// Уровней четыре: shot/series/session — привязаны к части тренировки,
/// coach — отдельный от них чат с тренером (страница "Тренер" на
/// рабочем столе), не фильтр по автору поверх session, а свой уровень:
/// иначе сообщение спортсмена оттуда пряталось бы от него самого же
/// (не тот author_role) и всплывало в общей ленте "Заметки".
class CommentsThreadSheet extends StatefulWidget {
  final CommentLevel level;
  final String? shotId;
  final int? seriesNo;

  const CommentsThreadSheet({
    super.key,
    required this.level,
    this.shotId,
    this.seriesNo,
  });

  // 0.8 вместо общих 0.7 — по запросу пользователя специально для
  // заметки к выстрелу: открывается чаще остальных уровней, из
  // длинного списка (см. shot_list_sheet.dart), где лишний простор
  // важнее.
  static Future<void> showForShot(BuildContext context, String shotId) => _show(
        context,
        CommentsThreadSheet(level: CommentLevel.shot, shotId: shotId),
        heightFactor: 0.8,
      );

  static Future<void> showForSeries(BuildContext context, int seriesNo) => _show(
        context,
        CommentsThreadSheet(level: CommentLevel.series, seriesNo: seriesNo),
      );

  static Future<void> showForSession(BuildContext context) => _show(
        context,
        const CommentsThreadSheet(level: CommentLevel.session),
      );

  /// Отдельный чат с тренером — не фильтр по автору поверх `session`
  /// (тем самым и от «Заметок» отделён по-настоящему: сообщение
  /// спортсмена отсюда видно здесь же, а не только тренеру).
  static Future<void> showForCoach(BuildContext context) => _show(
        context,
        const CommentsThreadSheet(level: CommentLevel.coach),
      );

  static Future<void> _show(BuildContext context, Widget child, {double heightFactor = 0.7}) {
    final vm = context.read<TargetViewModel>();
    final store = context.read<AppDataStore>();
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => Padding(
        // Без этого поле ввода уезжало под клавиатуру — showModalBottomSheet
        // не подвигает свой контент сам (жалоба пользователя: "не видно,
        // что пишешь" в заметке к выстрелу и в чате с тренером).
        padding: EdgeInsets.only(bottom: kIsWeb ? 0 : MediaQuery.of(ctx).viewInsets.bottom),
        child: FractionallySizedBox(
          heightFactor: heightFactor,
          child: MultiProvider(
            providers: [
              ChangeNotifierProvider.value(value: vm),
              ChangeNotifierProvider.value(value: store),
            ],
            child: child,
          ),
        ),
      ),
    );
  }

  @override
  State<CommentsThreadSheet> createState() => _CommentsThreadSheetState();
}

class _CommentsThreadSheetState extends State<CommentsThreadSheet> {
  final _controller = TextEditingController();
  static const _uuid = Uuid();

  @override
  Widget build(BuildContext context) {
    final vm = context.watch<TargetViewModel>();
    final store = context.watch<AppDataStore>();
    final repo = CommentsRepository(store.db);
    final comments = switch (widget.level) {
      CommentLevel.shot => repo.forShot(vm.session.id, widget.shotId!),
      CommentLevel.series => repo.forSeries(vm.session.id, widget.seriesNo!),
      CommentLevel.session => repo.forSession(vm.session.id),
      CommentLevel.coach => repo.forCoach(vm.session.id),
    };
    final df = DateFormat('dd.MM HH:mm');

    return SafeArea(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text(
              _titleFor(widget.level),
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: comments.isEmpty
                ? Center(
                    child: Text(widget.level == CommentLevel.coach
                        ? 'Переписки с тренером пока нет'
                        : 'Комментариев пока нет'),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.all(12),
                    itemCount: comments.length,
                    itemBuilder: (context, i) {
                      final c = comments[i];
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('${c.authorLabel}: ${df.format(c.createdAt)}',
                                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                                      fontWeight: FontWeight.w600,
                                    )),
                            Text(c.text),
                          ],
                        ),
                      );
                    },
                  ),
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.all(8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  controller: _controller,
                  minLines: 1,
                  maxLines: 4,
                  decoration: const InputDecoration(hintText: 'Написать комментарий…'),
                ),
                const SizedBox(height: 8),
                // Явные "Сохранить"/"Отмена" вместо одной кнопки-отправки
                // (решение пользователя) — Отмена просто стирает
                // черновик, ничего не отправляя.
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('Отмена'),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      onPressed: () {
                        if (_controller.text.trim().isEmpty) return;
                        final comment = Comment(
                          id: _uuid.v4(),
                          sessionId: vm.session.id,
                          level: widget.level,
                          shotId: widget.level == CommentLevel.shot ? widget.shotId : null,
                          seriesNo: widget.level == CommentLevel.series ? widget.seriesNo : null,
                          authorRole: store.workMode == WorkMode.coach ? AuthorRole.coach : AuthorRole.athlete,
                          text: _controller.text.trim(),
                          createdAt: DateTime.now(),
                        );
                        repo.add(comment);
                        vm.noteExternalEdit();
                        Navigator.of(context).pop();
                      },
                      child: const Text('Сохранить'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _titleFor(CommentLevel level) => switch (level) {
        CommentLevel.shot => 'Комментарии к выстрелу',
        CommentLevel.series => 'Комментарии к серии',
        CommentLevel.session => 'Комментарии к тренировке',
        CommentLevel.coach => 'Чат с тренером',
      };
}
