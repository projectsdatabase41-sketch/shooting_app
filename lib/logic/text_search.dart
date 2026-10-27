/// Ключевые слова и «болтовня — не вопрос» — общая часть поиска по
/// произвольному тексту (без морфологии, без эмбеддингов, просто
/// подстрочный поиск по стеблю слова). Раньше жила только в
/// `KnowledgeService` (поиск по shooting_rules/books); вынесена сюда,
/// чтобы `AiMemoryService` (поиск по прошлым разговорам, пункт 10
/// списка правок) не дублировал тот же список стоп-слов и ту же
/// логику стемминга.
class TextSearch {
  const TextSearch._();

  /// Слова короче этого в поиск не идут — от «как», «что», «мне» толку
  /// нет, а выдачу они размывают до бессмыслицы.
  static const int minWordLength = 5;

  /// Короче этого весь текст целиком считаем репликой, а не запросом к
  /// поиску (общее для `KnowledgeService` и `AiMemoryService`).
  static const int minQuestionLength = 8;

  /// Служебные слова, которые проходят по длине, но смысла не несут.
  static const Set<String> _stopWords = {
    'который',
    'которая',
    'потому',
    'нужно',
    'можно',
    'почему',
    'сколько',
    'какой',
    'какая',
    'какие',
    'когда',
    'сейчас',
    'вообще',
    'вопрос',
    'ответь',
    'скажи',
    'расскажи',
    'подскажи',
    'объясни',
    'пожалуйста',
    'максимальная',
    'максимальный',
    'максимально',
    'минимальная',
    'минимальный',
    'минимально',
    'разрешено',
    'разрешается',
    'допустимо',
    'допускается',
    'правильно',
    'обычно',
    'лучше',
    'должен',
    'должна',
    'должно',
    // Просьбы и вежливость — не предмет поиска (раньше «можешь», «предложить» попадали в поиск как слова).
    'можешь',
    'можете',
    'предложи',
    'предложить',
    'предлагай',
    'помоги',
    'помогите',
    'подскажите',
    'посоветуй',
    'посоветуйте',
    'расскажите',
    'объясните',
    'хочу',
    'хотел',
    'хотела',
  };

  /// Короткие, но значимые слова предметной области (меньше minWordLength).
  static const Set<String> _shortTerms = {
    'лук', 'вдох', 'цель', 'пуля', 'упор', 'руки', 'рука', 'глаз', 'темп',
    'ствол', 'мушка', 'спуск', 'нерв',
  };

  /// Ключевые слова текста.
  ///
  /// Морфологии нет, поэтому у длинных слов берём только основу —
  /// первые 6 букв. «стрельбе», «стрельбы», «стрельбой» превращаются в
  /// «стрель» и находят друг друга. Грубо, но для подстрочного поиска
  /// работает лучше, чем точное совпадение словоформы.
  ///
  /// Кроме длинных слов в поиск идут и значимые короткие: аббревиатуры
  /// (ISSF, IPSC, МВ, ПП), слова с цифрами («10м», «3х20», «50m») и
  /// несколько терминов предметной области (вдох, цель, лук…) — раньше они
  /// отбрасывались по длине, и вопрос про них искал не то.
  static List<String> keywords(String text, {int maxWords = 4}) {
    final tokens = text
        .replaceAll(RegExp(r'[^\wа-яёА-ЯЁ\s]', unicode: true), ' ')
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty);

    final special = <String>[]; // аббревиатуры, слова с цифрами, термины
    final words = <String>[];
    for (final t in tokens) {
      final lw = t.toLowerCase();
      if (_stopWords.contains(lw)) continue;
      final hasDigit = RegExp(r'\d').hasMatch(lw);
      final hasLetter = RegExp(r'[a-zа-яё]').hasMatch(lw);
      final isAcronym = t.length >= 2 &&
          t.length <= 6 &&
          t == t.toUpperCase() &&
          RegExp(r'^[A-ZА-ЯЁ]+$').hasMatch(t);
      if (_shortTerms.contains(lw) ||
          isAcronym ||
          (hasDigit && hasLetter && lw.length >= 2)) {
        special.add(lw);
      } else if (lw.length >= minWordLength && !hasDigit) {
        words.add(lw);
      }
    }

    // Длинные слова информативнее коротких — берём их первыми.
    words.sort((a, b) => b.length.compareTo(a.length));

    final stems = <String>[];
    for (final w in [...special, ...words]) {
      final stem = w.length > 6 ? w.substring(0, 6) : w;
      if (!stems.contains(stem)) stems.add(stem);
      if (stems.length >= maxWords) break;
    }
    return stems;
  }

  /// Начала реплик, за которыми в поиск лезть незачем.
  ///
  /// На «Добро» поиск честно шёл искать по книгам: слово проходило и
  /// по длине, и мимо стоп-листа. Намеренно список префиксов, а не
  /// регулярка: в Dart `\w`/`\b` работают только по ASCII, и
  /// `привет\w*\b` на кириллице просто не сработал бы.
  static const List<String> smallTalkPrefixes = [
    'привет',
    'здравств',
    'добр',
    'хай',
    'спасибо',
    'пока',
    'ага',
    'как дела',
    'как сам',
    'что умеешь',
    'кто ты',
    'что ты умеешь',
  ];

  /// Вопрос про само приложение или ассистента («что это за приложение», «что ты умеешь», «кто ты»): ответ в самом
  /// ассистенте, книги не нужны — иначе слово «приложение» находило «Приложение B» из учебника.
  static final _aboutAppRe = RegExp(
      r'(что|кто)\s+(это\s+)?за\s+(приложени|программ)|(что|расскаж)[^.?!]{0,30}\s(об?|про)\s+(этом\s+)?(приложени|nexus|нексус|тебе|себе)|что ты умеешь|кто ты($|[^а-яё])',
      caseSensitive: false);

  static bool isAboutApp(String text) => _aboutAppRe.hasMatch(text.trim().toLowerCase());

  static bool isSmallTalk(String text) {
    final t = text.trim().toLowerCase();
    return smallTalkPrefixes.any(t.startsWith) || isAboutApp(t);
  }

  /// Сколько разных ключевых слов встретилось в тексте — для
  /// ранжирования результатов по релевантности вопросу.
  /// Вес с учётом заголовка: слово в заголовке раздела (3) важнее слова в тексте (1) —
  /// раздел «Динамическое прицеливание как способ концентрации» должен обгонять случайные упоминания.
  static int weightedRelevance(String heading, String text, List<String> words) {
    final h = heading.toLowerCase(), t = text.toLowerCase();
    var n = 0;
    for (final w in words) {
      if (h.contains(w)) n += 3;
      if (t.contains(w)) n += 1;
    }
    return n;
  }

  static int relevance(String haystack, List<String> words) {
    final hay = haystack.toLowerCase();
    var n = 0;
    for (final w in words) {
      if (hay.contains(w)) n++;
    }
    return n;
  }
}
