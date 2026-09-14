import 'package:flutter/material.dart';

/// Полоска над полем ввода, пока выбран "ответ на сообщение" — цитата +
/// крестик отмены, как в Telegram/WhatsApp. Общая для личного и общего
/// чата: обе ленты хранят разные типы сообщений, поэтому сюда приходит
/// уже готовый текст цитаты, а не само сообщение.
class ChatReplyBar extends StatelessWidget {
  final String preview;
  final VoidCallback onCancel;
  const ChatReplyBar({super.key, required this.preview, required this.onCancel});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHigh,
        border: Border(top: BorderSide(color: theme.dividerColor)),
      ),
      child: Row(
        children: [
          Container(width: 3, height: 32, color: theme.colorScheme.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(preview, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall),
          ),
          IconButton(icon: const Icon(Icons.close, size: 18), onPressed: onCancel),
        ],
      ),
    );
  }
}
