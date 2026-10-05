import 'package:flutter_test/flutter_test.dart';
import 'package:shooting_app/services/web_search_service.dart';

void main() {
  test('разбор ответа Gemini: текст и уникальные источники', () {
    final r = WebSearchService.parse({
      'candidates': [
        {
          'content': {
            'parts': [
              {'text': 'Ответ '},
              {'text': 'готов'},
            ],
          },
          'groundingMetadata': {
            'groundingChunks': [
              {
                'web': {'uri': 'https://a.example', 'title': 'A'}
              },
              {
                'web': {'uri': 'https://a.example', 'title': 'A'}
              },
              {
                'web': {'uri': 'https://b.example', 'title': 'B'}
              },
            ],
          },
        },
      ],
    });
    expect(r.text, 'Ответ готов');
    expect(r.sources.map((s) => s.url),
        ['https://a.example', 'https://b.example']);
    expect(() => WebSearchService.parse({'candidates': []}), throwsException);
  });
}
