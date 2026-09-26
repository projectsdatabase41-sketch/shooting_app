import 'package:flutter/material.dart';
import '../i18n/i18n.dart';

/// Диалог "применить или откатить" при выходе с экрана мишени, когда
/// завершённая тренировка была разблокирована и в ней что-то поменяли
/// (пункт 12/13 списков правок). Общий для всех мест, откуда можно
/// покинуть тренировку — раньше стоял только в `PopScope` экрана
/// мишени и не срабатывал при переключении нижних вкладок.
///
/// `null` — диалог закрыли, не выбрав ничего (тап мимо/системное
/// "назад" внутри диалога): вызывающий код должен остаться на месте,
/// ничего не решая.
Future<bool?> confirmFinishedEditExit(BuildContext context) {
  return showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(tr('Хотите применить изменения?')),
      content: Text(
        tr('Вы поправили уже завершённую тренировку. Применить изменения или вернуть её к тому виду, что был до разблокировки?'),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: Text(tr('Вернуть как было')),
        ),
        FilledButton(
          onPressed: () => Navigator.of(ctx).pop(true),
          child: Text(tr('Применить')),
        ),
      ],
    ),
  );
}
