import 'local_db_service.dart';
import 'chat_messages_repository.dart';

class ChatVault {
  static bool get supported => false;
  static bool isOn(LocalDbService db) => false;
  static void setOn(LocalDbService db, bool v) {}
  static Future<bool> ensureAccess() async => false;
  static Future<int> sync(LocalDbService db) async => 0;
  static Future<bool> exists() async => false;
  static Future<int> restore(LocalDbService db, ChatMessagesRepository repo) async => 0;
  static Future<void> syncIfOn(LocalDbService db) async {}
}
