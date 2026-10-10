import 'package:flutter_test/flutter_test.dart';
import 'package:shooting_app/services/coach_call.dart';

void main() {
  test('вызов тренера: тело запроса к серверу звонков', () {
    final b = CoachCall.body('https://abcdefgh1234.supabase.co', 'anon', 'jwt-token', 'ivan');
    expect(b, {
      'db': 'https://abcdefgh1234.supabase.co',
      'key': 'anon',
      'jwt': 'jwt-token',
      'kind': 'call',
      'who': 'ivan',
    });
  });
}
