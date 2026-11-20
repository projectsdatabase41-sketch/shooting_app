import 'package:flutter/material.dart';

import '../i18n/i18n.dart';
import '../services/sync_status.dart';
import '../widgets/app_backdrop.dart';
import '../widgets/glass_pill.dart';

/// Страница прогресса синхронизации с облаком. Открывается тапом по
/// индикатору в углу главного экрана; сама синхронизация от этого экрана
/// не зависит (см. `SyncStatus`).
class SyncProgressScreen extends StatelessWidget {
  const SyncProgressScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: GlassHeader(title: Text(tr('Синхронизация с облаком'))),
      body: AppBackdrop(
        kind: 'settings',
        child: ValueListenableBuilder<SyncState>(
          valueListenable: SyncStatus.state,
          builder: (context, s, _) {
            return ListView(
              padding: EdgeInsets.fromLTRB(
                  16, MediaQuery.paddingOf(context).top + GlassHeader.height + 16, 16, 32),
              children: [
                Row(children: [
                  if (s.running)
                    const SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(strokeWidth: 2.5))
                  else
                    Icon(
                      s.failed ? Icons.error_outline : Icons.cloud_done_outlined,
                      size: 24,
                      color: s.failed ? theme.colorScheme.error : theme.colorScheme.primary,
                    ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(s.running ? s.title : tr('Готово'),
                        style: theme.textTheme.titleMedium),
                  ),
                ]),
                if (s.running) ...[
                  const SizedBox(height: 16),
                  Text(
                    tr('Можно закрыть эту страницу и продолжать работать: синхронизация идёт в фоне, а индикатор остаётся в углу главного экрана.'),
                    style: theme.textTheme.bodySmall,
                  ),
                ],
                if (s.message != null && s.message!.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  Text(s.message!, style: theme.textTheme.bodyMedium),
                ],
                const SizedBox(height: 24),
                OutlinedButton.icon(
                  onPressed: () => Navigator.of(context).maybePop(),
                  icon: const Icon(Icons.arrow_back),
                  label: Text(tr('Вернуться')),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
