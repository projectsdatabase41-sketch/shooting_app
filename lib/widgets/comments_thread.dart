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
/// всех трёх уровнях независимо от роли/статуса тренировки — в отличие
/// от canEdit (C.2).
class CommentsThreadSheet extends StatefulWidget {
  final CommentLevel level;
  final String? shotId;
  final int? seriesNo;

  /// Показывать только записи тренера.
  ///
  /// Нужно для отдельной страницы «Тренер» на рабочем столе: разбор от
  /// тренера — это не то же самое, что собственные заметки спортсмена,
  /// и смешивать их в одной ленте значит терять и то, и другое.
  final bool coachOnly;

  const CommentsThreadSheet({
    super.key,
    required this.level,
    this.shotId,
    this.seriesNo,
    this.coachOnly = false,
  });

  static Future<void> showForShot(BuildContext context, String shotId) => _show(
        context,
        CommentsThreadSheet(level: CommentLevel.shot, shotId: shotId),
      );

  static Future<void> showForSeries(BuildContext context, int seriesNo) => _show(
        context,
        CommentsThreadSheet(level: CommentLevel.series, seriesNo: seriesNo),
      );

  static Future<void> showForSession(BuildContext context) => _show(
        context,
        const CommentsThreadSheet(level: CommentLevel.session),
      );

  static Future<void> _show(BuildContext context, Widget child) {
    final vm = context.read<TargetViewModel>();
    final store = context.read<AppDataStore>();
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (_) => FractionallySizedBox(
        heightFactor: 0.7,
        child: MultiProvider(
          providers: [
            ChangeNotifierProvider.value(value: vm),
            ChangeNotifierProvider.value(value: store),
          ],
          child: child,
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
    final all = switch (widget.level) {
      CommentLevel.shot => repo.forShot(vm.session.id, widget.shotId!),
      CommentLevel.series => repo.forSeries(vm.session.id, widget.seriesNo!),
      CommentLevel.session => repo.forSession(vm.session.id),
    };
    final comments = widget.coachOnly
        ? all.where((c) => c.authorRole == AuthorRole.coach).toList()
        : all;
    final df = DateFormat('dd.MM HH:mm');

    return SafeArea(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text(
              widget.coachOnly ? 'Разбор от тренера' : _titleFor(widget.level),
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: comments.isEmpty
                ? Center(
                    child: Text(widget.coachOnly
                        ? 'Тренер пока ничего не написал'
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
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _controller,
                    decoration: const InputDecoration(hintText: 'Написать комментарий…'),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.send),
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
                    _controller.clear();
                    setState(() {});
                  },
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
      };
}
