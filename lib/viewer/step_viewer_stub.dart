import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'step_viewer_common.dart';

/// Не-веб платформы: встроенного iframe нет, а тянуть 9 МБ wasm (OCCT)
/// в APK ради редкой вкладки нерационально — открываем тот же вьюер в
/// системном браузере. Файл выбирается там же, разбор идёт локально.
Widget buildViewer(BuildContext context) =>
    stepViewerFallback(context, openExternally);

Future<void> openExternally(BuildContext context) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  try {
    final ok = await launchUrl(Uri.parse(stepViewerPublicUrl),
        mode: LaunchMode.externalApplication);
    if (!ok) {
      messenger?.showSnackBar(const SnackBar(
          content: Text('Не удалось открыть браузер')));
    }
  } catch (e) {
    messenger?.showSnackBar(SnackBar(content: Text('$e')));
  }
}
