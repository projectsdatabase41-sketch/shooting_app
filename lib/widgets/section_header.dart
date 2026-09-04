import 'package:flutter/material.dart';

/// Заголовок раздела внутри экрана — общий элемент оформления.
///
/// До введения общей темы заголовки разделов писались по месту как
/// `Text(..., style: TextStyle(fontWeight: FontWeight.bold))`, каждый со
/// своими отступами; отсюда бралась разнобойность экранов.
class SectionHeader extends StatelessWidget {
  final String title;
  final String? subtitle;

  /// Действие справа от заголовка (кнопка "все", "добавить" и т.п.).
  final Widget? trailing;

  const SectionHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(title, style: theme.textTheme.titleMedium),
              if (subtitle != null) ...[
                const SizedBox(height: 2),
                Text(subtitle!, style: theme.textTheme.bodySmall),
              ],
            ],
          ),
        ),
        if (trailing != null) trailing!,
      ],
    );
  }
}
