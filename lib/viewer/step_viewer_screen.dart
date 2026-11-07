import 'package:flutter/material.dart';

import '../i18n/i18n.dart';
import 'step_viewer_stub.dart' if (dart.library.html) 'step_viewer_web.dart' as impl;

/// Просмотр 3D-моделей (STEP/GLB) внутри приложения.
///
/// Сам вьюер — статический сайт в `web/viewer/` (three.js + OpenCascade в
/// wasm). Он публикуется вместе с веб-сборкой приложения по адресу
/// `<сайт приложения>/viewer/`, поэтому здесь только оболочка: на вебе —
/// iframe того же origin, на остальных платформах — та же страница в
/// системном браузере (см. `step_viewer_stub.dart`).
class StepViewerScreen extends StatelessWidget {
  const StepViewerScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(tr('3D-модели')),
        actions: [
          IconButton(
            tooltip: tr('Открыть в браузере'),
            icon: const Icon(Icons.open_in_new),
            onPressed: () => impl.openExternally(context),
          ),
        ],
      ),
      body: impl.buildViewer(context),
    );
  }
}
