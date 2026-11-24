import 'package:flutter/material.dart';

import '../i18n/i18n.dart';
import '../logic/friendly_error.dart' show friendlyErrorDevMode;

/// Мост к JS API вьюера `window.NexusViewer` (assets/webview/app.js,
/// просьба владельца 24.11): приложение вызывает те же функции, что и
/// кнопки самого вьюера, поэтому поведение не дублируется.
///
/// Здесь описан только общий контракт (одинаковый для step_viewer_io и
/// step_viewer_web): конкретный мост собирает платформенная реализация.
class StepViewerJs {
  const StepViewerJs(
      {required this.hasJs, required this.invoke, required this.ready});

  /// Есть ли вообще доступ к странице вьюера: на Android — WebView-контроллер,
  /// на вебе моста нет (JS iframe снаружи не достать, требование B).
  final bool hasJs;

  /// Вьюер догрузился и отдаёт публичный API `window.NexusViewer` — можно
  /// звать методы. До этого (и при потере моста) экран знает, что вьюер
  /// надо пересоздавать с параметром `?url=` вместо вызова `load()`.
  final bool ready;

  /// Вызов `window.NexusViewer.<method>(…)`. Возвращает результат JS либо
  /// `null`, если мост ещё не готов (страница не догрузилась) — тогда
  /// вызывающий пересоздаёт вьюер с параметром `?url=` (требование B).
  final Future<Object?> Function(String method, List<Object?> args) invoke;

  /// Загрузить модель по ссылке. true — приняла (`load()` вернул результат);
  /// false — вьюер ещё не готов, нужно открыть страницу заново с `?url=`.
  Future<bool> loadModel(String url) async {
    try {
      final res = await invoke('load', [url]);
      // null — моста ещё нет; false — модель по ссылке не принята.
      return res == true || res == 'true';
    } catch (_) {
      // Страница в середине перезагрузки: считаем мост не готовым —
      // экран откроет вьюер заново с параметром url.
      return false;
    }
  }

  /// «Рёбра» — включить/выключить показ рёбер (
  /// `NexusViewer.edges(on)`). Состояние кнопки хранит сам экран, потому
  /// что спросить вьюер снаружи нельзя (требование A, п.3).
  Future<void> setEdges(bool on) async {
    try {
      await invoke('edges', [on]);
    } catch (_) {
      // Мост пропал (страница перезагружается) — молча: состояние уже
      // сохранено в кнопке и применится при следующем вызове.
    }
  }

  /// «Свойства» — панель масса/центр тяжести/объём/материал.
  Future<void> openMass() async {
    try {
      await invoke('mass', [true]);
    } catch (_) {}
  }

  /// «Отображение» — заливка «дымом»/прозрачность для оценки объёма.
  Future<void> openDisplay() async {
    try {
      await invoke('display', [true]);
    } catch (_) {}
  }
}

/// Типовой экран ошибки каталога (требование D): понятный текст, кнопка
/// «Повторить», а в режиме разработчика — ещё и код ошибки (обычному
/// пользователю код не показываем — см. `friendly_error.dart`).
Widget catalogErrorView(
  BuildContext context, {
  required String? errorCode,
  required VoidCallback onRetry,
}) {
  final theme = Theme.of(context);
  return Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.wifi_off_outlined,
              size: 40, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(height: 12),
          Text(
            tr('Не удалось загрузить каталог'),
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium,
          ),
          // Код ошибки — только разработчику: обычному пользователю
          // «HTTP 401» ничего не говорит (правило friendly-ошибок).
          if (friendlyErrorDevMode && errorCode != null) ...[
            const SizedBox(height: 4),
            Text(
              '${tr('Код ошибки')}: $errorCode',
              textAlign: TextAlign.center,
              style: theme.textTheme.labelSmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ],
          const SizedBox(height: 8),
          FilledButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh, size: 18),
            label: Text(tr('Повторить')),
          ),
        ],
      ),
    ),
  );
}

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
