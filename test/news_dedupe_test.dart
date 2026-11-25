import 'package:flutter_test/flutter_test.dart';
import 'package:shooting_app/services/news_service.dart';

NewsItem _n(String title, String link, String date, {String source = 'tfb'}) => NewsItem(
      title: title,
      link: link,
      source: source,
      date: date,
      summary: '',
    );

void main() {
  group('дедупликация новостей (отзыв eabeec17)', () {
    test('одинаковая ссылка с utm-хвостом и www — одна новость', () {
      final out = NewsService.dedupe([
        _n('Заголовок А', 'https://www.example.com/a?utm_source=rss', 'Tue, 24 Nov 2026 10:00:00 +0000'),
        _n('Заголовок А', 'https://example.com/a/', 'Tue, 24 Nov 2026 09:00:00 +0000'),
      ]);
      expect(out.length, 1);
      expect(out.first.link, contains('utm_source')); // остался первый (свежий)
    });

    test('одинаковый заголовок из разных источников — одна новость', () {
      final out = NewsService.dedupe([
        _n('Vortex Pro', 'https://a.example/1', 'Tue, 24 Nov 2026 10:00:00 +0000', source: 'a'),
        _n('  vortex   pro ', 'https://b.example/2', 'Tue, 24 Nov 2026 08:00:00 +0000', source: 'b'),
      ]);
      expect(out.length, 1);
      expect(out.first.source, 'a');
    });

    test('сортировка по дате: свежие сверху, без даты — в конце', () {
      final out = NewsService.dedupe([
        _n('Старая', 'https://example.com/old', 'Mon, 17 Nov 2026 10:00:00 +0000'),
        _n('Без даты', 'https://example.com/nodate', ''),
        _n('Новая', 'https://example.com/new', 'Tue, 24 Nov 2026 10:00:00 +0000'),
      ]);
      expect([for (final n in out) n.title], ['Новая', 'Старая', 'Без даты']);
    });

    test('пустой список не падает', () {
      expect(NewsService.dedupe([]), isEmpty);
    });
  });
}
