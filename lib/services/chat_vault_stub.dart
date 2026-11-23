import 'chat_messages_repository.dart';
import 'local_db_service.dart';

class ChatVault {
  static bool get supported => false;
  static bool isOn(LocalDbService db) => false;
  static void setOn(LocalDbService db, bool v) {}
  static Future<bool> ensureAccess() async => false;
  static Future<bool> hasKey() async => false;
  static Future<bool> hasVaultFile() async => false;
  static Future<bool> setPassword(String password) async => false;

  // Те же необязательные параметры прогресса/отмены, что у Android-версии:
  // экран настроек один для всех платформ (см. chat_vault_io.dart).
  static Future<int> sync(LocalDbService db,
          {void Function(int done, int total)? onProgress, bool Function()? cancelled, Duration? budget}) async =>
      0;
  static Future<bool> exists() async => false;
  static Future<int> restore(LocalDbService db, ChatMessagesRepository repo,
          {void Function(int done, int total)? onProgress, bool Function()? cancelled}) async =>
      0;
  static Future<void> migrateLegacy(LocalDbService db, ChatMessagesRepository repo,
      {void Function(int done, int total)? onProgress, bool Function()? cancelled}) async {}
  static Future<void> syncIfOn(LocalDbService db, {Duration budget = const Duration(seconds: 8)}) async {}
}
