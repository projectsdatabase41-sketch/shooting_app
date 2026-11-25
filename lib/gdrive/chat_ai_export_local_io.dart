import 'dart:io' show File;

/// Чтение локального файла вложения для выгрузки на Диск (мобильные и
/// десктоп). Веб-вариант — `chat_ai_export_local_web.dart`.
///
/// Отзыв 25.11 (b2f77808): вынесено в отдельный файл, чтобы `dart:io` не
/// попадал в сборку веба (из-за него падал deploy-web).
Future<List<int>?> readLocalBytes(String path, {required int maxBytes}) async {
  try {
    final f = File(path);
    if (!await f.exists()) return null;
    final bytes = await f.readAsBytes();
    return bytes.length <= maxBytes ? bytes : null;
  } catch (_) {
    return null;
  }
}
