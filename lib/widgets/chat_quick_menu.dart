import 'package:flutter/material.dart';

/// Одно действие в меню долгого нажатия — только иконка, без подписи
/// (решение пользователя: "плитки без текста, интуитивно понятно"),
/// текст остаётся лишь всплывающей подсказкой для доступности.
class ChatQuickAction {
  final String value;
  final IconData icon;
  final String label;
  final Color? color;
  const ChatQuickAction({required this.value, required this.icon, required this.label, this.color});
}

RelativeRect _popupPosition(BuildContext context, Offset at) {
  final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
  return RelativeRect.fromRect(Rect.fromPoints(at, at), Offset.zero & overlay.size);
}

/// Маленькое окошко рядом с местом нажатия вместо полноэкранного листа
/// снизу — ряд кнопок-иконок, тап по любой сразу закрывает меню с её
/// значением.
Future<String?> showChatQuickMenu(BuildContext context, Offset at, List<ChatQuickAction> actions) {
  return showMenu<String>(
    context: context,
    position: _popupPosition(context, at),
    color: Theme.of(context).colorScheme.surfaceContainerHigh,
    elevation: 10,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
    items: [
      PopupMenuItem<String>(
        enabled: false,
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 0),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final a in actions)
              Tooltip(
                message: a.label,
                child: InkWell(
                  borderRadius: BorderRadius.circular(20),
                  onTap: () => Navigator.of(context).pop(a.value),
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: Icon(a.icon, size: 20, color: a.color),
                  ),
                ),
              ),
          ],
        ),
      ),
    ],
  );
}

/// "Облачко" с текстом ошибки перевода — тап по красному значку перевода
/// рядом с сообщением. Тот же приём позиционирования, что и у меню
/// действий, только показывает текст, а не набор кнопок.
void showChatErrorBubble(BuildContext context, Offset at, String message) {
  showMenu<void>(
    context: context,
    position: _popupPosition(context, at),
    color: Theme.of(context).colorScheme.errorContainer,
    elevation: 10,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
    items: [
      PopupMenuItem<void>(
        enabled: false,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 240),
          child: Text(
            message,
            style: TextStyle(color: Theme.of(context).colorScheme.onErrorContainer),
          ),
        ),
      ),
    ],
  );
}
