import 'package:flutter/material.dart';

import 'glass_pill.dart';

/// Карточка над полем ввода, пока выбран "ответ на сообщение": кому
/// отвечаем, цитата и крестик — стеклянная, как поле ввода. Сюда приходит
/// уже готовый текст цитаты, а не само сообщение.
class ChatReplyBar extends StatelessWidget {
  final String preview;
  final String title;
  final VoidCallback onCancel;
  const ChatReplyBar({super.key, required this.preview, this.title = 'Ответ', required this.onCancel});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = theme.colorScheme.primary;
    return GlassPill(
      radius: 18,
      padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
      child: Row(
        children: [
          Icon(Icons.reply, color: accent, size: 22),
          const SizedBox(width: 10),
          Container(
            width: 3,
            height: 34,
            decoration: BoxDecoration(color: accent, borderRadius: BorderRadius.circular(2)),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelLarge?.copyWith(color: accent, fontWeight: FontWeight.w700)),
                Text(preview, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall),
              ],
            ),
          ),
          IconButton(icon: const Icon(Icons.close, size: 20), onPressed: onCancel),
        ],
      ),
    );
  }
}
