import 'package:flutter/material.dart';

import '../i18n/i18n.dart';

/// Адрес вьюера на опубликованном сайте — для платформ без встроенного показа.
const stepViewerPublicUrl =
    'https://projectsdatabase41-sketch.github.io/shooting_app/viewer/';

/// Заглушка для платформ, где встроенного показа нет: объясняет, что
/// произойдёт, и даёт одну кнопку.
Widget stepViewerFallback(
        BuildContext context, Future<void> Function(BuildContext) open) =>
    Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.view_in_ar_outlined, size: 64),
            const SizedBox(height: 16),
            Text(tr('Просмотр STEP и GLB'),
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              tr('Модель откроется в браузере: разбор STEP идёт локально, файл никуда не отправляется.'),
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: () => open(context),
              icon: const Icon(Icons.open_in_new),
              label: Text(tr('Открыть вьюер')),
            ),
          ],
        ),
      ),
    );
