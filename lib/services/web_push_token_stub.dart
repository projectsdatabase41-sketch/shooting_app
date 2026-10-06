Future<String?> webPushToken(
        Map<String, String> config, String vapidKey) async =>
    null;

/// 'ok' вне веба — проверять нечего.
String webPushEnv() => 'ok';

Future<String> webRequestPermission() async => 'granted';

void webSetActiveChat(String? contactId) {}
