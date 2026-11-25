/// Веб: локальных путей к файлам нет — вложения приходят base64 из базы,
/// этот путь всегда пустой. См. `chat_ai_export_local_io.dart`.
Future<List<int>?> readLocalBytes(String path, {required int maxBytes}) async => null;
