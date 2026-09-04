import 'package:flutter/material.dart';

/// Удаление свайпом справа налево — с подтверждением.
///
/// Решение пользователя: «удаление можно сделать свайпом справа налево
/// до конца экрана (почти до конца), но с подтверждением удаления».
/// Отсюда две особенности против стандартного `Dismissible`:
///
/// 1. Порог смахивания поднят до [_threshold] — случайным движением
///    пальца по списку карточку не снести, нужно осознанно провести её
///    почти через весь экран.
/// 2. Свайп ничего не удаляет сам: он только ОТКРЫВАЕТ диалог. Пока
///    пользователь не подтвердил, элемент возвращается на место, и
///    список не мигает исчезающей строкой.
class SwipeToDelete extends StatelessWidget {
  /// Уникальный ключ строки — по нему `Dismissible` отличает элементы.
  final String itemKey;

  /// Заголовок и текст диалога подтверждения.
  final String title;
  final String message;

  /// Подпись кнопки подтверждения. По умолчанию «Удалить».
  final String confirmLabel;

  /// Подпись кнопки отказа. По умолчанию «Отмена» — но у шуточного
  /// вопроса «Зря создал?» уместнее «Нет».
  final String cancelLabel;

  /// Вызывается только после подтверждения.
  final VoidCallback onConfirmed;

  final Widget child;

  const SwipeToDelete({
    super.key,
    required this.itemKey,
    required this.title,
    required this.message,
    required this.onConfirmed,
    required this.child,
    this.confirmLabel = 'Удалить',
    this.cancelLabel = 'Отмена',
  });

  /// Насколько далеко надо провести, чтобы жест засчитался.
  ///
  /// Стандартные 0.4 ширины срабатывают от небрежного движения при
  /// прокрутке; 0.85 — это «почти до конца экрана».
  static const double _threshold = 0.85;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Dismissible(
      key: ValueKey(itemKey),
      direction: DismissDirection.endToStart,
      dismissThresholds: const {DismissDirection.endToStart: _threshold},
      background: const SizedBox.shrink(),
      secondaryBackground: Padding(
        // Те же отступы, что у карточек списка, иначе красная плашка
        // торчит из-под них по краям.
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Container(
          decoration: BoxDecoration(
            color: cs.errorContainer,
            borderRadius: BorderRadius.circular(12),
          ),
          alignment: Alignment.centerRight,
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.end,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Удалить',
                style: TextStyle(color: cs.onErrorContainer, fontWeight: FontWeight.w600),
              ),
              const SizedBox(width: 8),
              Icon(Icons.delete_outline, color: cs.onErrorContainer),
            ],
          ),
        ),
      ),
      confirmDismiss: (_) async {
        final ok = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text(title),
            content: Text(message),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: Text(cancelLabel),
              ),
              FilledButton(
                style: FilledButton.styleFrom(backgroundColor: cs.error),
                onPressed: () => Navigator.of(ctx).pop(true),
                child: Text(confirmLabel),
              ),
            ],
          ),
        );
        if (ok != true) return false;
        onConfirmed();
        // false, а не true: строку из списка убирает уже само хранилище,
        // и если вернуть true, Dismissible попытается анимировать
        // удаление виджета, которого в дереве больше нет.
        return false;
      },
      child: child,
    );
  }
}
