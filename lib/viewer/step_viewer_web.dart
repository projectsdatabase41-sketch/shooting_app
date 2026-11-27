import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../i18n/i18n.dart';
import 'step_viewer_common.dart';

/// Веб: встроенный iframe конфликтует с Flutter-слоем — Flutter рисует
/// поверх сцены синюю заглушку platform view (отзыв 27.11). Отдельная
/// вкладка работает нормально, поэтому на вебе 3D открывается в новой
/// вкладке, а здесь — карточка с кнопкой.
Widget buildViewer(
  BuildContext context, {
  String? modelUrl,
  void Function(StepViewerJs? js)? onJs,
  VoidCallback? onOpenCatalog,
}) {
  final uri = Uri.base
      .resolve('assets/assets/webview/index.html')
      .replace(queryParameters: (modelUrl == null || modelUrl.isEmpty) ? null : {'url': modelUrl});
  final cs = Theme.of(context).colorScheme;
  return ColoredBox(
    color: const Color(0xFF121417),
    child: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: Card(
          color: cs.surfaceContainerHigh,
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.threed_rotation, size: 40, color: cs.primary),
              const SizedBox(height: 10),
              Text(tr('3D-модель открывается в новой вкладке'),
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
              const SizedBox(height: 6),
              Text(
                tr('На вебе встроенная сцена перекрывается интерфейсом, поэтому модель показывается отдельной страницей. Выберите модель в каталоге — вкладка откроется сама.'),
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 14),
              Wrap(spacing: 8, runSpacing: 8, alignment: WrapAlignment.center, children: [
                FilledButton.icon(
                  onPressed: () => launchUrl(uri, webOnlyWindowName: '_blank'),
                  icon: const Icon(Icons.open_in_new),
                  label: Text(tr('Открыть 3D в новой вкладке')),
                ),
                if (onOpenCatalog != null)
                  OutlinedButton.icon(
                    onPressed: onOpenCatalog,
                    icon: const Icon(Icons.grid_view_outlined),
                    label: Text(tr('Каталог')),
                  ),
              ]),
            ]),
          ),
        ),
      ),
    ),
  );
}
