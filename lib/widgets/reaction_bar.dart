import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:flutter/material.dart';

/// Панель реакций прямо под сообщением: одна строка на 5 смайликов с
/// горизонтальной прокруткой, шестая ячейка — кнопка «вниз», раскрывающая
/// панель до 5 строк со всеми смайликами. Сначала идут недавние.
class ReactionBar extends StatefulWidget {
  /// Недавно использованные — показываются первыми.
  final List<String> recent;

  /// Моя текущая реакция на это сообщение (подсвечивается).
  final String? mine;
  final ValueChanged<String> onPick;
  const ReactionBar({super.key, required this.recent, required this.onPick, this.mine});

  static const double cell = 44;

  /// Базовый набор — для тех, у кого ещё нет недавних.
  static const List<String> quick = ['👍', '❤️', '😂', '😮', '😢', '🙏', '🔥', '👎'];

  static List<String>? _all;

  /// Все смайлики клавиатуры (из набора emoji_picker_flutter), без дублей.
  static List<String> get allEmojis => _all ??= [
        for (final c in defaultEmojiSet)
          if (c.category != Category.RECENT) for (final e in c.emoji) e.emoji
      ];

  /// Порядок показа: недавние, базовые, остальные.
  static List<String> ordered(List<String> recent) =>
      <String>{...recent, ...quick, ...allEmojis}.toList();

  @override
  State<ReactionBar> createState() => _ReactionBarState();
}

class _ReactionBarState extends State<ReactionBar> {
  bool _expanded = false;
  late final List<String> _items = ReactionBar.ordered(widget.recent);

  Widget _cell(String e) {
    final cs = Theme.of(context).colorScheme;
    return InkResponse(
      onTap: () => widget.onPick(e),
      radius: 22,
      child: Container(
        width: ReactionBar.cell,
        height: ReactionBar.cell,
        alignment: Alignment.center,
        decoration: e == widget.mine
            ? BoxDecoration(color: cs.primary.withValues(alpha: 0.25), shape: BoxShape.circle)
            : null,
        child: Text(e, style: const TextStyle(fontSize: 26)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    const w = ReactionBar.cell * 6;
    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 2),
      child: Container(
        width: w + 8,
        decoration: BoxDecoration(
          color: cs.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(_expanded ? 18 : 24),
          boxShadow: [
            BoxShadow(color: Colors.black.withValues(alpha: 0.3), blurRadius: 8, offset: const Offset(2, -2)),
          ],
        ),
        padding: const EdgeInsets.all(4),
        child: _expanded
            ? Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    height: ReactionBar.cell * 5,
                    child: GridView.builder(
                      padding: EdgeInsets.zero,
                      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 6),
                      itemCount: _items.length,
                      itemBuilder: (_, i) => _cell(_items[i]),
                    ),
                  ),
                  SizedBox(
                    height: 32,
                    child: IconButton(
                      padding: EdgeInsets.zero,
                      tooltip: '',
                      icon: const Icon(Icons.expand_less),
                      onPressed: () => setState(() => _expanded = false),
                    ),
                  ),
                ],
              )
            : SizedBox(
                height: ReactionBar.cell,
                child: Row(
                  children: [
                    Expanded(
                      child: ListView.builder(
                        scrollDirection: Axis.horizontal,
                        itemExtent: ReactionBar.cell,
                        itemCount: _items.length,
                        itemBuilder: (_, i) => _cell(_items[i]),
                      ),
                    ),
                    SizedBox(
                      width: ReactionBar.cell,
                      child: IconButton(
                        padding: EdgeInsets.zero,
                        icon: const Icon(Icons.expand_more),
                        onPressed: () => setState(() => _expanded = true),
                      ),
                    ),
                  ],
                ),
              ),
      ),
    );
  }
}
