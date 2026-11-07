import 'dart:ui_web' as ui_web;

import 'package:flutter/material.dart';
import 'package:web/web.dart' as web;

/// Веб: вьюер живёт рядом с приложением (`<base>/viewer/`), поэтому
/// показываем его обычным iframe того же origin — без WebView-плагинов и
/// без 9 МБ в APK. `Uri.base` даёт адрес страницы, от него и считаем путь:
/// на GitHub Pages это `/shooting_app/viewer/`, при `flutter run` — `/viewer/`.
const _viewType = 'step-viewer-frame';
bool _registered = false;

Widget buildViewer(BuildContext context) {
  if (!_registered) {
    ui_web.platformViewRegistry.registerViewFactory(_viewType, (int _) {
      final frame = web.document.createElement('iframe') as web.HTMLIFrameElement;
      frame.src = Uri.base.resolve('viewer/index.html').toString();
      frame.style.border = 'none';
      frame.style.width = '100%';
      frame.style.height = '100%';
      frame.setAttribute('allow', 'fullscreen');
      frame.setAttribute('title', 'STEP viewer');
      return frame;
    });
    _registered = true;
  }
  // Тёмный фон под загрузку страницы вьюера — чтобы не мелькала белая вспышка.
  return const ColoredBox(
    color: Color(0xFF121417),
    child: HtmlElementView(viewType: _viewType),
  );
}

Future<void> openExternally(BuildContext context) async {
  web.window.open(Uri.base.resolve('viewer/index.html').toString(), '_blank');
}
