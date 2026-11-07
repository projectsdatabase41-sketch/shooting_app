import 'package:flutter/material.dart';

import '../i18n/i18n.dart';
import 'step_viewer_io.dart'
    if (dart.library.html) 'step_viewer_web.dart' as impl;

/// Просмотр 3D-моделей (STEP/GLB) внутри приложения.
///
/// Сам вьюер — статический сайт в `assets/webview/` (three.js +
/// OpenCascade в wasm), он же копируется в APK. Файл выбирается с
/// телефона или открывается по ссылке; разбор идёт на устройстве, файл
/// никуда не отправляется.
class StepViewerScreen extends StatefulWidget {
  /// Модель, открытая по ссылке (или переданная из другого экрана).
  final String? modelUrl;

  const StepViewerScreen({super.key, this.modelUrl});

  @override
  State<StepViewerScreen> createState() => _StepViewerScreenState();
}

class _StepViewerScreenState extends State<StepViewerScreen> {
  String? _url;

  @override
  void initState() {
    super.initState();
    _url = widget.modelUrl;
  }

  Future<void> _openByLink() async {
    final controller = TextEditingController(text: _url ?? '');
    final value = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('Открыть по ссылке')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: controller,
              autofocus: true,
              keyboardType: TextInputType.url,
              decoration: InputDecoration(
                hintText: 'https://…/model.stp',
                labelText: tr('Адрес файла'),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              tr('Файл скачается и разберётся на устройстве. Ссылка должна открываться без пароля.'),
              style: Theme.of(ctx).textTheme.bodySmall,
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: Text(tr('Отмена'))),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
            child: Text(tr('Открыть')),
          ),
        ],
      ),
    );
    if (value == null || value.isEmpty || !mounted) return;
    setState(() => _url = value);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(tr('3D-модели')),
        actions: [
          IconButton(
            tooltip: tr('Открыть по ссылке'),
            icon: const Icon(Icons.link),
            onPressed: _openByLink,
          ),
        ],
      ),
      body: impl.buildViewer(context, modelUrl: _url),
    );
  }
}
