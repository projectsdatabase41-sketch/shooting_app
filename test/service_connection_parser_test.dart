import 'package:flutter_test/flutter_test.dart';
import 'package:shooting_app/logic/service_connection_parser.dart';

void main() {
  group('ServiceConnectionParser', () {
    test('ссылку на веб-страницу Airtable подменяет на её REST API', () {
      final parsed = ServiceConnectionParser.fromUrl(
        'https://airtable.com/appdnsIGg6jUzsr7O/tblNC3xn7pp4AxxFS/viw7A7I4IdYedSwzf?blocks=hide',
      );
      expect(parsed.url, 'https://api.airtable.com/v0/appdnsIGg6jUzsr7O/tblNC3xn7pp4AxxFS');
    });

    test('уже правильный адрес API Airtable не трогает', () {
      final parsed = ServiceConnectionParser.fromUrl('https://api.airtable.com/v0/appXXX/tblYYY');
      expect(parsed.url, 'https://api.airtable.com/v0/appXXX/tblYYY');
    });

    test('обычную ссылку не трогает', () {
      final parsed = ServiceConnectionParser.fromUrl('https://drive.google.com/drive/folders/abc');
      expect(parsed.url, 'https://drive.google.com/drive/folders/abc');
    });

    test('нормализует и в JSON-описании подключения', () {
      final parsed = ServiceConnectionParser.fromJson(
        '{"url": "https://airtable.com/appdnsIGg6jUzsr7O/tblNC3xn7pp4AxxFS", "headers": {"Authorization": "Bearer x"}}',
      );
      expect(parsed.url, 'https://api.airtable.com/v0/appdnsIGg6jUzsr7O/tblNC3xn7pp4AxxFS');
    });
  });
}
