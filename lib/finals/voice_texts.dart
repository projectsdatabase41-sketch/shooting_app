/// Тексты озвучки финалов по языкам и сборка фраз из записей.
///
/// Записи двух видов: общие (команды и числа — одинаковы для всех) и именные
/// («Лидирует {имя}», «Второй {имя}», «{имя}, четвёртое место», «Выбывает {имя}») — их приложение
/// заранее озвучивает для каждого имени. Фраза рейтинга склеивается: именная запись + числа счёта.
class VoiceTexts {
  VoiceTexts._();

  /// Языки, для которых есть тексты озвучки; для остальных берётся английский.
  static const languages = ['ru', 'en', 'de', 'zh'];
  static String langFor(String uiCode) => languages.contains(uiCode) ? uiCode : 'en';

  /// «Бот» в озвучке не произносится: «Бывалый (Bot)» → «Бывалый».
  static String spokenName(String name) =>
      name.replaceAll(RegExp(r'\s*\((?:Bot|Бот)\)\s*$', caseSensitive: false), '').trim();

  // ---- общие записи ----
  static const _commands = <String, Map<String, String>>{
    'ru': {'cmd_sighting': 'Пристрелка.', 'cmd_load': 'Заряжай.', 'cmd_start': 'Старт.', 'cmd_stop': 'Стоп.', 'cmd_finished': 'Финал окончен.'},
    'en': {'cmd_sighting': 'Sighting shots.', 'cmd_load': 'Load.', 'cmd_start': 'Start.', 'cmd_stop': 'Stop.', 'cmd_finished': 'Final finished.'},
    'de': {'cmd_sighting': 'Probeschüsse.', 'cmd_load': 'Laden.', 'cmd_start': 'Start.', 'cmd_stop': 'Stopp.', 'cmd_finished': 'Finale beendet.'},
    'zh': {'cmd_sighting': '试射。', 'cmd_load': '装弹。', 'cmd_start': '开始。', 'cmd_stop': '停止。', 'cmd_finished': '决赛结束。'},
  };

  static const _small = <String, List<String>>{
    'ru': ['ноль', 'один', 'два', 'три', 'четыре', 'пять', 'шесть', 'семь', 'восемь', 'девять', 'десять', 'одиннадцать', 'двенадцать', 'тринадцать', 'четырнадцать', 'пятнадцать', 'шестнадцать', 'семнадцать', 'восемнадцать', 'девятнадцать'],
    'en': ['zero', 'one', 'two', 'three', 'four', 'five', 'six', 'seven', 'eight', 'nine', 'ten', 'eleven', 'twelve', 'thirteen', 'fourteen', 'fifteen', 'sixteen', 'seventeen', 'eighteen', 'nineteen'],
    'de': ['null', 'eins', 'zwei', 'drei', 'vier', 'fünf', 'sechs', 'sieben', 'acht', 'neun', 'zehn', 'elf', 'zwölf', 'dreizehn', 'vierzehn', 'fünfzehn', 'sechzehn', 'siebzehn', 'achtzehn', 'neunzehn'],
    'zh': ['零', '一', '二', '三', '四', '五', '六', '七', '八', '九', '十', '十一', '十二', '十三', '十四', '十五', '十六', '十七', '十八', '十九'],
  };

  /// Десятки 20…90, сотни 100…300, разделитель.
  static const _big = <String, Map<String, String>>{
    'ru': {'num_020': 'двадцать', 'num_030': 'тридцать', 'num_040': 'сорок', 'num_050': 'пятьдесят', 'num_060': 'шестьдесят', 'num_070': 'семьдесят', 'num_080': 'восемьдесят', 'num_090': 'девяносто', 'num_100': 'сто', 'num_200': 'двести', 'num_300': 'триста', 'num_comma': 'запятая'},
    'en': {'num_020': 'twenty', 'num_030': 'thirty', 'num_040': 'forty', 'num_050': 'fifty', 'num_060': 'sixty', 'num_070': 'seventy', 'num_080': 'eighty', 'num_090': 'ninety', 'num_100': 'one hundred', 'num_200': 'two hundred', 'num_300': 'three hundred', 'num_comma': 'point'},
    'de': {'num_020': 'zwanzig', 'num_030': 'dreißig', 'num_040': 'vierzig', 'num_050': 'fünfzig', 'num_060': 'sechzig', 'num_070': 'siebzig', 'num_080': 'achtzig', 'num_090': 'neunzig', 'num_100': 'hundert', 'num_200': 'zweihundert', 'num_300': 'dreihundert', 'num_comma': 'Komma'},
    'zh': {'num_020': '二十', 'num_030': '三十', 'num_040': '四十', 'num_050': '五十', 'num_060': '六十', 'num_070': '七十', 'num_080': '八十', 'num_090': '九十', 'num_100': '一百', 'num_200': '二百', 'num_300': '三百', 'num_comma': '点'},
  };

  /// Все общие записи языка: id → текст.
  static Map<String, String> common(String lang) {
    final l = langFor(lang);
    return {
      ..._commands[l]!,
      for (var i = 0; i < 20; i++) 'num_${i.toString().padLeft(3, '0')}': _small[l]![i],
      ..._big[l]!,
    };
  }

  // ---- именные записи ----
  /// Шаблоны: id → текст с {n} (имя). Порядок по тексту диктора: лидер, 2-й, 3-й, выбывает, места 4–8.
  static const _named = <String, Map<String, String>>{
    'ru': {'leads': 'Лидирует {n}.', 'p2': 'Второй {n}.', 'p3': 'Третий {n}.', 'out': 'Выбывает {n}.', 'pl4': '{n}, четвёртое место.', 'pl5': '{n}, пятое место.', 'pl6': '{n}, шестое место.', 'pl7': '{n}, седьмое место.', 'pl8': '{n}, восьмое место.'},
    'en': {'leads': 'Leading {n}.', 'p2': 'Second {n}.', 'p3': 'Third {n}.', 'out': 'Eliminated {n}.', 'pl4': '{n}, fourth place.', 'pl5': '{n}, fifth place.', 'pl6': '{n}, sixth place.', 'pl7': '{n}, seventh place.', 'pl8': '{n}, eighth place.'},
    'de': {'leads': 'Es führt {n}.', 'p2': 'Zweiter {n}.', 'p3': 'Dritter {n}.', 'out': 'Ausgeschieden {n}.', 'pl4': '{n}, vierter Platz.', 'pl5': '{n}, fünfter Platz.', 'pl6': '{n}, sechster Platz.', 'pl7': '{n}, siebter Platz.', 'pl8': '{n}, achter Platz.'},
    'zh': {'leads': '领先：{n}。', 'p2': '第二：{n}。', 'p3': '第三：{n}。', 'out': '淘汰：{n}。', 'pl4': '{n}，第四名。', 'pl5': '{n}，第五名。', 'pl6': '{n}，第六名。', 'pl7': '{n}，第七名。', 'pl8': '{n}，第八名。'},
  };

  static List<String> namedIds() => _named['ru']!.keys.toList();

  /// Именные записи для [name]: шаблон → готовый текст.
  static Map<String, String> namedTexts(String lang, String name) =>
      {for (final e in _named[langFor(lang)]!.entries) e.key: e.value.replaceAll('{n}', name)};

  /// Ссылка на именную запись в списке фраз: `name:<шаблон>:<имя>`.
  static String namedRef(String template, String name) => 'name:$template:$name';

  // ---- числа ----
  /// Счёт 105,3 → записи: «сто», «пять», «запятая», «три». Нормальный счёт финала — до 300.
  static List<String> numberRefs(double value) {
    final tenths = (value * 10).round().clamp(0, 3000);
    final i = tenths ~/ 10, d = tenths % 10;
    String n(int v) => 'num_${v.toString().padLeft(3, '0')}';
    final out = <String>[];
    var rest = i;
    if (rest >= 100) {
      out.add(n((rest ~/ 100) * 100));
      rest %= 100;
      if (rest == 0) {
        out
          ..add('num_comma')
          ..add(n(d));
        return out;
      }
    }
    if (rest >= 20) {
      out.add(n(rest ~/ 10 * 10));
      if (rest % 10 > 0) out.add(n(rest % 10));
    } else if (rest > 0 || out.isEmpty) {
      out.add(n(rest));
    }
    out
      ..add('num_comma')
      ..add(n(d));
    return out;
  }
}
