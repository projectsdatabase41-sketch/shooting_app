import 'package:flutter_test/flutter_test.dart';
import 'package:shooting_app/services/chat_auth_service.dart';
import 'package:shooting_app/services/local_db_service.dart';
import 'package:shooting_app/services/chat_settings.dart';
import 'package:shooting_app/services/remote_config.dart';

void main() {
  tearDown(() => RemoteConfig.setForTest({}));

  test('по умолчанию всё выключено, опрос ×1', () {
    RemoteConfig.setForTest({});
    expect(RemoteConfig.realtimeEnabled, isFalse);
    expect(RemoteConfig.webrtcEnabled, isFalse);
    expect(RemoteConfig.pollScale, 1.0);
    expect(RemoteConfig.pushQuietSeconds, 120);
  });

  test('WebRTC включается только вместе с Realtime', () {
    RemoteConfig.setForTest({'webrtc': {'enabled': true}});
    expect(RemoteConfig.webrtcEnabled, isFalse);
    RemoteConfig.setForTest({'realtime': {'enabled': true}, 'webrtc': {'enabled': true}});
    expect(RemoteConfig.webrtcEnabled, isTrue);
  });

  test('чужой адрес чат-базы отвергается, свой supabase.co принимается только с ключом', () {
    final def = ChatSettings.url;
    for (final bad in ['http://x.supabase.co', 'https://evil.com', 'https://x.supabase.co.evil.com', 'https://x.supabase.co/rest']) {
      RemoteConfig.setForTest({'chat': {'url': bad, 'anonKey': 'sb_publishable_x'}});
      expect(ChatSettings.url, def, reason: bad);
    }
    RemoteConfig.setForTest({'chat': {'url': 'https://abc.supabase.co'}});
    expect(ChatSettings.url, def); // без ключа не переключаемся
    RemoteConfig.setForTest({'chat': {'url': 'https://abc.supabase.co', 'anonKey': 'sb_publishable_x'}});
    expect(ChatSettings.url, 'https://abc.supabase.co');
    expect(ChatSettings.anonKey, 'sb_publishable_x');
  });

  test('stun: только stun:-адреса, иначе значение по умолчанию', () {
    RemoteConfig.setForTest({'webrtc': {'stun': ['turn:secret@x', 5]}});
    expect(RemoteConfig.stunServers, ['stun:stun.l.google.com:19302']);
    RemoteConfig.setForTest({'webrtc': {'stun': ['stun:a.b:3478']}});
    expect(RemoteConfig.stunServers, ['stun:a.b:3478']);
  });

  test('pollScale: некорректное значение → 1', () {
    RemoteConfig.setForTest({'poll': {'scale': 'много'}});
    expect(RemoteConfig.pollScale, 1.0);
    RemoteConfig.setForTest({'poll': {'scale': 3}});
    expect(RemoteConfig.pollScale, 3.0);
  });

  test('сервер мессенджера переехал — старый вход недействителен, новый вход действителен', () async {
    final db = LocalDbService();
    await db.open(overridePath: ':memory:');
    final auth = ChatAuthService(db);
    // вход до переезда: отметки сервера нет → считается прежним сервером
    db.db.execute("INSERT INTO project_settings (id, chat_access_token) VALUES (1, 'old') "
        "ON CONFLICT(id) DO UPDATE SET chat_access_token = 'old'");
    expect(auth.isSignedIn, ChatSettings.url == 'https://frbptucrvmyikencyspu.supabase.co');
    db.db.execute('UPDATE project_settings SET chat_server_url = ? WHERE id = 1', [ChatSettings.url]);
    expect(auth.isSignedIn, isTrue);
  });
}
