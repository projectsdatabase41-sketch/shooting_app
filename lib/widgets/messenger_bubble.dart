import 'package:flutter/material.dart';

import '../services/chat_preferences.dart';

/// Пузырь сообщения в стиле мессенджера (комментарии, чат с тренером): цвета и скругление — из
/// настроек оформления чата, время снаружи под пузырём.
class MessengerBubble extends StatelessWidget {
  final String text;

  /// Подпись автора над текстом (у чужих сообщений); null — без подписи.
  final String? author;
  final bool mine;
  final ChatPreferences prefs;
  final String time;
  final VoidCallback onLongPress;
  const MessengerBubble(
      {super.key,
      required this.text,
      this.author,
      required this.mine,
      required this.prefs,
      required this.time,
      required this.onLongPress});

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
                    if (author != null)
                      Text(author!,
                          style: theme.textTheme.labelMedium?.copyWith(color: fg, fontWeight: FontWeight.w700)),
                    Text(text,
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
