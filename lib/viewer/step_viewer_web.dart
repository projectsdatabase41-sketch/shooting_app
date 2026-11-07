import 'package:flutter/material.dart';
import 'dart:ui_web' as ui_web;

import 'package:web/web.dart' as web;

/// Веб: вьюер лежит в ассетах приложения (`assets/assets/webview/`),
/// поэтому показываем его iframe того же origin — без плагинов и без
/// отдельной публикации сайта вьюера.
Widget buildViewer(BuildContext context, {String? modelUrl}) {
  var uri = Uri.base.resolve('assets/assets/webview/index.html');
  if (modelUrl != null && modelUrl.isNotEmpty) {
    uri = uri.replace(queryParameters: {'url': modelUrl});
  }
  // Свой тип представления на каждый адрес: при открытии по ссылке src
  // должен смениться, а фабрика регистрируется один раз на тип.
  final viewType = 'step-viewer-${uri.toString().hashCode}';
  ui_web.platformViewRegistry.registerViewFactory(viewType, (int _) {
    final frame = web.document.createElement('iframe') as web.HTMLIFrameElement;
    frame.src = uri.toString();
    frame.style.border = 'none';
    frame.style.width = '100%';
    frame.style.height = '100%';
    frame.setAttribute('allow', 'fullscreen');
    frame.setAttribute('title', 'STEP viewer');
    return frame;
  });
  // Тёмный фон под загрузку страницы вьюера — чтобы не мелькала белая вспышка.
  return ColoredBox(
    color: const Color(0xFF121417),
    child: HtmlElementView(viewType: viewType),
  );
}
