/// Папка «Nexus» в памяти телефона с файлами и историей чатов: переживает удаление приложения.
/// Работает только на Android (в вебе и на других платформах — заглушка).
export 'chat_vault_stub.dart' if (dart.library.io) 'chat_vault_io.dart';
