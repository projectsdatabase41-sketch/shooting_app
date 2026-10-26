import 'package:flutter_test/flutter_test.dart';
import 'package:shooting_app/logic/text_search.dart';
import 'package:shooting_app/services/knowledge_service.dart';

void main() {
  profileFilterTests();
  retrievalTests();
  test('вопрос про концентрацию внимания находит и близкие слова (сосредоточение, психология)', () {
    final words = KnowledgeService.withSynonyms(KnowledgeService.keywords('методы концентрации внимания перед выстрелом'));
    expect(words, containsAll(['концен', 'вниман']));
    expect(words.any((w) => w.startsWith('сосред')), isTrue);
    expect(words.length, lessThanOrEqualTo(10));
  });
}

void retrievalTests() {
  test('просьбы вроде «можешь предложить» не попадают в поисковые слова', () {
    final w = KnowledgeService.keywords('можешь предложить методы концентрации внимания перед выстрелом');
    expect(w, isNot(contains('можешь')));
    expect(w.any((x) => x.startsWith('предл')), isFalse);
    expect(w, containsAll(['концен', 'вниман']));
  });

  test('слово в заголовке раздела весит больше, чем случайное упоминание в тексте', () {
    final words = ['концен', 'вниман'];
    final byHeading = TextSearch.weightedRelevance('Динамическое прицеливание как способ концентрации внимания', 'Стрелок медленно вводит оружие в мишень', words);
    final byText = TextSearch.weightedRelevance('Рекомендации по тренировке', 'Короткие тренировки с максимальной концентрацией внимания.', words);
    expect(byHeading, greaterThan(byText));
  });

  test('куски про стендовую стрельбу не подмешиваются к ответам для винтовки и пистолета', () {
    const clay = 'Необходимо направлять умственное усилие на траектории полёта мишени и движение ружья в положение выстрела.';
    const rifle = 'Стрелок медленно вводит оружие в мишень и производит выстрел через 1-2 секунды.';
    expect(KnowledgeService.clayMismatch({'rifle'}, clay), isTrue);
    expect(KnowledgeService.clayMismatch({'pistol', 'rifle'}, clay), isTrue);
    expect(KnowledgeService.clayMismatch({'shotgun'}, clay), isFalse); // стендовик — его материал
    expect(KnowledgeService.clayMismatch({}, clay), isFalse); // анкета не заполнена — не отбрасываем
    expect(KnowledgeService.clayMismatch({'rifle'}, rifle), isFalse);
  });
}

void profileFilterTests() {
  test('вид оружия берётся из анкеты, если вопрос его не называет', () {
    const rifleText = 'Приклад прижат к плечу, щека на гребне приклада.';
    const pistolText = 'Хват пистолета: рука вытянута, пистолет удерживается одной рукой.';
    expect(KnowledgeService.weaponMismatch('как держать', rifleText, profileDisciplines: {'pistol'}), isTrue);
    expect(KnowledgeService.weaponMismatch('как держать', pistolText, profileDisciplines: {'rifle'}), isTrue);
    expect(KnowledgeService.weaponMismatch('как держать', pistolText, profileDisciplines: {'pistol'}), isFalse);
    expect(KnowledgeService.weaponMismatch('как держать', rifleText, profileDisciplines: {'pistol', 'rifle'}), isFalse);
    expect(KnowledgeService.weaponMismatch('как держать', rifleText), isFalse); // анкета пуста
    // вопрос важнее анкеты
    expect(KnowledgeService.weaponMismatch('хват винтовки', pistolText, profileDisciplines: {'pistol'}), isTrue);
  });

  test('пол из анкеты: куски только про другую категорию отбрасываются', () {
    expect(KnowledgeService.genderMismatch('m', 'Программа для женщин: 60 выстрелов.'), isTrue);
    expect(KnowledgeService.genderMismatch('f', 'ВП-60, мужчины, 60 выстрелов.'), isTrue);
    expect(KnowledgeService.genderMismatch('m', 'Мужчины и женщины стреляют по одной программе.'), isFalse);
    expect(KnowledgeService.genderMismatch('m', 'Дыхание и пауза перед выстрелом.'), isFalse);
    expect(KnowledgeService.genderMismatch('', 'Программа для женщин.'), isFalse);
  });
}
