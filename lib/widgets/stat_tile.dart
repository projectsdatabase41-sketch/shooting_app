import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

/// Плитка с крупным числовым показателем — общий элемент оформления
/// (статистика, сводка тренировки).
///
/// Раньше такие плитки собирались прямо в экране статистики из голого
/// `Card` + `Text` с хардкодом `Colors.grey.shade600`, из-за чего не
/// работала тёмная тема и цифры терялись. Здесь всё берётся из
/// `Theme.of(context)`.
class StatTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;

  /// Вторая строка мелким шрифтом под значением: «мин 9.4 · макс 10.8»,
  /// «218 целыми». Крупное число отвечает на вопрос сразу, уточнение
  /// стоит рядом и не спорит с ним за внимание.
  final String? hint;

  /// Подсветить значение акцентным (янтарным) цветом — для главных
  /// показателей, чтобы плитки не выглядели одинаково серыми.
  final bool accent;

  const StatTile({
    super.key,
    required this.icon,
    required this.label,
    required this.value,
    this.hint,
    this.accent = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final valueColor = accent ? AppTheme.accentFor(cs) : cs.onSurface;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    color: cs.surfaceContainerHigh,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(icon, size: 16, color: cs.onSurfaceVariant),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    label,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelMedium?.copyWith(color: cs.onSurfaceVariant),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(
                value,
                style: theme.textTheme.headlineMedium?.copyWith(color: valueColor),
              ),
            ),
            if (hint != null) ...[
              const SizedBox(height: 4),
              Text(
                hint!,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelSmall?.copyWith(color: cs.onSurfaceVariant),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
