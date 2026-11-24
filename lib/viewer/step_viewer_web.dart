import 'dart:ui_web' as ui_web;

import 'package:flutter/material.dart';
import 'package:web/web.dart' as web;

import 'step_viewer_common.dart';

/// Веб: вьюер лежит в ассетах приложения (`assets/assets/webview/`),
/// поэтому показываем его iframe того же origin — без плагинов и без
/// отдельной публикации сайта вьюера.
///
/// Моста `window.NexusViewer` снаружи iframe не достать: [onJs] на вебе
/// не вызывается никогда, а «Открыть STEP» работает через показ вьюера в
/// полном режиме (со своей шапкой) — требование A/B, владелец 24.11.
Widget buildViewer(
  BuildContext context, {
  String? modelUrl,
  bool embed = true,
  void Function(StepViewerJs? js)? onJs,
}) {
  var uri = Uri.base.resolve('assets/assets/webview/index.html');
  final params = <String, String>{
    // Приложение само рисует верхнюю панель — собственную шапку вьюера
    // прячем (поддержка embed в assets/webview, владелец 24.11).
    if (embed) 'embed': '1',
    if (modelUrl != null && modelUrl.isNotEmpty) 'url': modelUrl,
  };
  if (params.isNotEmpty) uri = uri.replace(queryParameters: params);
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
