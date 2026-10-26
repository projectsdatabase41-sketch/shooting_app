import 'package:flutter_test/flutter_test.dart';
import 'package:shooting_app/logic/source_quotes.dart';
import 'package:shooting_app/services/knowledge_service.dart';

KnowledgeChunk _c(String table, String source, String heading, String text) =>
    KnowledgeChunk(table: table, tableLabel: table, source: source, heading: heading, text: text);

const _dyn = 'Еще один из способов удержать доминирующее внимание на мышцах и нажиме на спуск это динамическое прицеливание. '
    'На практике это выглядит следующим образом. Стрелок медленно вводит оружие в мишень с какой либо стороны (принципиальной разницы нет ), '
    'подводит к центру и через 1-2 максимум 3 сек. производит выстрел. Иногда происходит остановка на несколько секунд в какой либо части мишени '
    'недалеко от центра (в габарите 8 или 9), а далее подводится к центру и также 1-2 секунды и выстрел. '
    'При анализе техники прицеливания сильнейших стрелков такая техника встречается в 70% случаев. И чаще, когда стрелки находится в хорошей форме и показывают высокие результаты.';

void main() {
  final words = KnowledgeService.withSynonyms(KnowledgeService.keywords('методы концентрации внимания перед выстрелом'));

  test('цитата — дословный текст книги со своим источником, окно из целых предложений', () {
    final q = SourceQuotes.pick([
      _c('books', 'Model_vystrela_i_pritselivanie.pdf', 'Model_vystrela_i_pritselivanie.pdf / Динамическое прицеливание как способ концентрации', _dyn),
      _c('books', 'x.pdf', 'x.pdf / Другое', 'Совсем о другом: погода и освещение.'),
    ], words);
    expect(q.length, 1);
    expect(q.first.text, contains('через 1-2 максимум 3 сек. производит выстрел'));
    expect(q.first.text, contains('70% случаев'));
    // ни одного слова не добавлено: каждый фрагмент есть в исходном тексте
    for (final part in q.first.text.split(RegExp(r'…\s*'))) {
      if (part.trim().isNotEmpty) expect(_dyn, contains(part.trim()));
    }
  });

  test('личные таблицы пользователя не цитируются как книги; слабое совпадение — без цитат', () {
    final personal = [_c('notes', 'мои заметки', 'концентрация внимания', 'концентрация внимания перед выстрелом')];
    expect(SourceQuotes.pick(personal, words, excludeTables: {'notes'}), isEmpty);
    expect(SourceQuotes.pick([_c('books', 'a.pdf', 'a.pdf / Погода', 'Сегодня солнечно.')], words), isEmpty);
  });

  test('длинный кусок режется по предложениям вокруг слов вопроса', () {
    final filler = List.generate(40, (i) => 'Предложение номер $i про другое.').join(' ');
    final text = '$filler Концентрация внимания на спуске даёт результат. Это важно. $filler';
    final w = SourceQuotes.window(text, ['концен', 'вниман'], 300);
    expect(w.length, lessThan(340));
    expect(w, contains('Концентрация внимания на спуске даёт результат.'));
    expect(w.startsWith('…'), isTrue);
  });

  test('оформление: номер, кавычки, источник без расширения и имени файла в разделе', () {
    final s = SourceQuotes.render(
        [const SourceQuote('Model_vystrela_i_pritselivanie.pdf', 'Model_vystrela_i_pritselivanie.pdf / Динамическое прицеливание', 'Текст.')],
        heading: 'Из материалов (дословно):');
    expect(s, contains('1. «Текст.»'));
    expect(s, contains('— Model vystrela i pritselivanie — Динамическое прицеливание'));
  });
}
