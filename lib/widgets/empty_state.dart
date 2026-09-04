import 'package:flutter/material.dart';

/// Пустое состояние списка — общий элемент оформления.
///
/// До общей темы каждый экран рисовал своё: где-то голый
/// `Center(child: Text(...))`, где-то `Icon(..., color: Colors.grey)` с
/// хардкодом цвета (не работал в тёмной теме). Здесь одна форма на всё
/// приложение: иконка, текст и, если есть, действие.
class EmptyState extends StatelessWidget {
  final IconData icon;
  final String text;
  final Widget? action;

  const EmptyState({
    super.key,
    required this.icon,
    required this.text,
    this.action,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: cs.surfaceContainerHigh,
                shape: BoxShape.circle,
              ),
              child: Icon(icon, size: 32, color: cs.onSurfaceVariant),
            ),
            const SizedBox(height: 16),
            Text(
              text,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
            ),
            if (action != null) ...[
              const SizedBox(height: 20),
              action!,
            ],
          ],
        ),
      ),
    );
  }
}
