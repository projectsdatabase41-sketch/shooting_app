import 'package:flutter_test/flutter_test.dart';
import 'package:shooting_app/services/coach_access_service.dart';
import 'package:shooting_app/services/coach_links_sync.dart';

void main() {
  test('зеркало подключения: все поля и статус попадают в тело upsert', () {
    const a = CoachAthlete(
      id: 'ath-1',
      name: 'Мария',
      url: 'https://abcdefgh.supabase.co',
      anonKey: 'anon-key',
      token: 'share-token',
    );
    final body = CoachLinksSync.payload(a, 'valid');
    expect(body['athlete_id'], 'ath-1');
    expect(body['name'], 'Мария');
    expect(body['supabase_url'], 'https://abcdefgh.supabase.co');
    expect(body['supabase_anon_key'], 'anon-key');
    expect(body['share_token'], 'share-token');
    expect(body['token_status'], 'valid');
  });

  test('отозванный токен помечается revoked', () {
    const a = CoachAthlete(id: 'a', name: 'n', url: 'u', anonKey: 'k', token: 't');
    expect(CoachLinksSync.payload(a, 'revoked')['token_status'], 'revoked');
  });
}
