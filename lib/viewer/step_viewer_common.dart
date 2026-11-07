import 'package:flutter/material.dart';

import '../i18n/i18n.dart';

/// Заглушка для платформ, где встроенного показа нет: объясняет, где
/// вьюер доступен, и (если передан [open]) даёт кнопку.
Widget stepViewerFallback(BuildContext context,
        {Future<void> Function(BuildContext)? open}) =>
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
              tr('Встроенный просмотр работает на Android и в веб-версии: файл разбирается прямо на устройстве, никуда не отправляется.'),
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            if (open != null) ...[
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: () => open(context),
                icon: const Icon(Icons.open_in_new),
                label: Text(tr('Открыть вьюер')),
              ),
            ],
          ],
        ),
      ),
    );
