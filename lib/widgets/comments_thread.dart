import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';
import '../models/comment.dart';
import '../services/chat_preferences.dart';
import '../services/comments_repository.dart';
import '../state/app_data_store.dart';
import '../state/target_view_model.dart';
import 'glass_pill.dart';

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
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

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
    final myRole = store.workMode == WorkMode.coach ? AuthorRole.coach : AuthorRole.athlete;
    final prefs = ChatPreferences(store.db);

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
                    child: Text(
                        widget.level == CommentLevel.coach ? 'Переписки с тренером пока нет' : 'Комментариев пока нет'),
                  )
                // Как в мессенджере: свои справа, собеседника слева, новые
                // внизу (лента перевёрнута и прижата к полю ввода).
                : ListView.builder(
                    reverse: true,
                    padding: const EdgeInsets.all(12),
                    itemCount: comments.length,
                    itemBuilder: (context, i) {
                      final c = comments[comments.length - 1 - i];
                      final mine = c.authorRole == myRole;
                      return _CommentBubble(
                        comment: c,
                        mine: mine,
                        prefs: prefs,
                        time: df.format(c.createdAt),
                        onLongPress: () => _showActions(context, repo, c, mine),
                      );
                    },
                  ),
          ),
          // Поле ввода с кнопкой отправки, без «Сохранить»/«Отмена» (решение
          // пользователя): лента живёт прямо на экране тренировки, и закрытие
          // по «Сохранить» выкидывало из неё. Отправил — поле очистилось,
          // остаёмся в переписке.
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: GlassPill(
                    radius: 25,
                    padding: const EdgeInsets.symmetric(horizontal: 18),
                    child: TextField(
                      controller: _controller,
                      minLines: 1,
                      maxLines: 4,
                      decoration: InputDecoration(
                        hintText: widget.level == CommentLevel.coach ? 'Сообщение тренеру…' : 'Написать комментарий…',
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        filled: false,
                        contentPadding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                GlassCircleButton(
                  size: 50,
                  tooltip: 'Отправить',
                  color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.85),
                  icon: Icon(Icons.send, color: Theme.of(context).colorScheme.onPrimary),
                  onTap: () {
                    final text = _controller.text.trim();
                    if (text.isEmpty) return;
                    repo.add(Comment(
                      id: _uuid.v4(),
                      sessionId: vm.session.id,
                      level: widget.level,
                      shotId: widget.level == CommentLevel.shot ? widget.shotId : null,
                      seriesNo: widget.level == CommentLevel.series ? widget.seriesNo : null,
                      authorRole: store.workMode == WorkMode.coach ? AuthorRole.coach : AuthorRole.athlete,
                      text: text,
                      createdAt: DateTime.now(),
                    ));
                    _controller.clear();
                    vm.noteExternalEdit();
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

  /// Меню "Изменить"/"Удалить" по долгому нажатию (пункт 6 списка
  /// правок) — тот же приём, что уже есть у сообщений ассистента.
  void _showActions(BuildContext context, CommentsRepository repo, Comment c, bool mine) {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.copy_outlined),
              title: const Text('Копировать'),
              onTap: () {
                Navigator.of(ctx).pop();
                Clipboard.setData(ClipboardData(text: c.text));
              },
            ),
            if (mine)
              ListTile(
                leading: const Icon(Icons.edit_outlined),
                title: const Text('Изменить'),
                onTap: () {
                  Navigator.of(ctx).pop();
                  _editComment(context, repo, c);
                },
              ),
            ListTile(
              leading: Icon(Icons.delete_outline, color: Theme.of(ctx).colorScheme.error),
              title: Text('Удалить', style: TextStyle(color: Theme.of(ctx).colorScheme.error)),
              onTap: () async {
                Navigator.of(ctx).pop();
                final ok = await showDialog<bool>(
                  context: context,
                  builder: (d) => AlertDialog(
                    title: const Text('Удалить сообщение?'),
                    actions: [
                      TextButton(onPressed: () => Navigator.of(d).pop(false), child: const Text('Отмена')),
                      FilledButton(onPressed: () => Navigator.of(d).pop(true), child: const Text('Удалить')),
                    ],
                  ),
                );
                if (ok != true) return;
                repo.delete(c.id);
                if (mounted) setState(() {});
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _editComment(BuildContext context, CommentsRepository repo, Comment c) async {
    final controller = TextEditingController(text: c.text);
    final text = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Изменить сообщение'),
        content: TextField(controller: controller, autofocus: true, minLines: 1, maxLines: 6),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Отмена')),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
            child: const Text('Сохранить'),
          ),
        ],
      ),
    );
    if (text == null || text.isEmpty) return;
    repo.update(c.id, text);
    if (mounted) setState(() {});
  }

  String _titleFor(CommentLevel level) => switch (level) {
        CommentLevel.shot => 'Комментарии к выстрелу',
        CommentLevel.series => 'Комментарии к серии',
        CommentLevel.session => 'Комментарии к тренировке',
        CommentLevel.coach => 'Чат с тренером',
      };
}

/// Пузырь комментария в стиле мессенджера: цвета и скругление — из
/// настроек оформления чата, время снаружи под пузырём.
class _CommentBubble extends StatelessWidget {
  final Comment comment;
  final bool mine;
  final ChatPreferences prefs;
  final String time;
  final VoidCallback onLongPress;
  const _CommentBubble(
      {required this.comment, required this.mine, required this.prefs, required this.time, required this.onLongPress});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final base = mine ? prefs.mineBubbleColor : prefs.otherBubbleColor;
    final fg = mine ? prefs.mineTextColor : prefs.otherTextColor;
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: GestureDetector(
        onLongPress: onLongPress,
        child: Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Column(
            crossAxisAlignment: mine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
            children: [
              Container(
                constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.78),
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(prefs.bubbleRadius),
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [Color.lerp(base, Colors.white, 0.08)!, Color.lerp(base, Colors.black, 0.10)!],
                  ),
                  boxShadow: prefs.shadowEnabled
                      ? [
                          BoxShadow(
                              color: Colors.black.withValues(alpha: prefs.shadowIntensity),
                              blurRadius: 10,
                              offset: const Offset(0, 4))
                        ]
                      : null,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (!mine)
                      Text(comment.authorLabel,
                          style: theme.textTheme.labelMedium?.copyWith(color: fg, fontWeight: FontWeight.w700)),
                    Text(comment.text,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: fg,
                          fontSize: (theme.textTheme.bodyMedium?.fontSize ?? 14) * prefs.fontScale,
                        )),
                  ],
                ),
              ),
              const SizedBox(height: 3),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Text(time, style: theme.textTheme.labelSmall?.copyWith(color: theme.hintColor)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
