/// Голосовые команды: разбор распознанной фразы в действие по правилам (без ИИ, бесплатно и мгновенно).
///
/// Правило универсальное, а не список готовых фраз: из фразы выбрасываются обращения и вежливость, потом ищутся
/// основы слов-глаголов, названия разделов и числа — порядок и падеж не важны («покажи мне пожалуйста статистику»,
/// «статистику открой», «в настройки»). Что именно можно сделать, зависит от РЕЖИМА — экрана, на котором человек
/// сейчас находится (тренировка, переписка, финал…): «десять пять на пять часов» в тренировке — выстрел на мишени,
/// а в переписке это просто слова. Всё, что не разобрано, уходит к ИИ-помощнику (если включён), который может только
/// выбрать действие из списка именно этого режима и вытащить параметры из слов человека.
enum VoiceAction {
  open, // открыть раздел: target — id вкладки
  back,
  trainingStart,
  trainingPause,
  trainingResume,
  trainingFinish,
  undoShot,
  addNote, // text — заметка к выстрелу (в тренировке)
  focusMode,
  finalReady,
  askAi, // text — вопрос ассистенту
  placeShot, // тренировка: score (например 10.5) и hour (направление по циферблату), text — заметка к выстрелу
  chatSearch, // переписка: query — слова, filter — photo | file | audio | video
  webSearch, // любая страница: query — что искать в интернете
  addDiaryNote, // любая страница: text — запись в «Заметки»
  createExercise, // любая страница: shots, face, text — название
}

/// Режимы (экраны), для которых есть свои команды.
class VoiceMode {
  VoiceMode._();
  static const training = 'training'; // открыта тренировка
  static const chat = 'chat'; // открыта переписка
  static const finalRun = 'final'; // финал
  static const home = 'home'; // главный экран
}

class VoiceIntent {
  final VoiceAction action;
  final String? target;
  final String? text;
  final double? score;
  final double? hour;
  final String? query;
  final String? filter;
  final int? shots;
  final String? face;
  const VoiceIntent(this.action,
      {this.target,
      this.text,
      this.score,
      this.hour,
      this.query,
      this.filter,
      this.shots,
      this.face});

  @override
  String toString() =>
      'VoiceIntent($action${target == null ? '' : ', $target'}${text == null ? '' : ', «$text»'}${score == null ? '' : ', $score'}${hour == null ? '' : ', $hour ч'}${query == null ? '' : ', q=$query'}${filter == null ? '' : ', f=$filter'}${shots == null ? '' : ', $shots выстр.'}${face == null ? '' : ', $face'})';

  @override
  bool operator ==(Object o) =>
      o is VoiceIntent &&
      o.action == action &&
      o.target == target &&
      o.text == text &&
      o.score == score &&
      o.hour == hour &&
      o.query == query &&
      o.filter == filter &&
      o.shots == shots &&
      o.face == face;

  @override
  int get hashCode => Object.hash(
      action, target, text, score, hour, query, filter, shots, face);
}

class VoiceGrammar {
  VoiceGrammar._();

  /// Что можно сказать про разделы: основа слова → id вкладки (совпадает с `home_tab_specs.dart`).
  static const Map<String, String> sections = {
    'тренировк': 'exercises',
    'упражнен': 'exercises',
    'статистик': 'statistics',
    'задани': 'tasks',
    'спортсмен': 'athletes',
    'ассистент': 'assistant',
    'помощник': 'assistant',
    'заметк': 'notes',
    'финал': 'finals',
    'мессенджер': 'messenger',
    'сообщени': 'messenger',
    'чат': 'messenger',
    'диск': 'drive',
    'настройк': 'settings',
  };

  static const _fillers = {
    'пожалуйста',
    'пж',
    'мне',
    'нам',
    'ка',
    'теперь',
    'давай',
    'давайте',
    'нексус',
    'эй',
    'окей',
    'слушай',
    'ну',
    'а',
    'и'
  };

  /// Числа словами: 0…12 (часы на циферблате и десятые доли результата).
  static const Map<String, int> numberWords = {
    'ноль': 0,
    'нуль': 0,
    'один': 1,
    'одна': 1,
    'одно': 1,
    'два': 2,
    'две': 2,
    'три': 3,
    'четыре': 4,
    'пять': 5,
    'шесть': 6,
    'семь': 7,
    'восемь': 8,
    'девять': 9,
    'десять': 10,
    'одиннадцать': 11,
    'двенадцать': 12,
  };

  static String normalizeWord(String w) => w
      .toLowerCase()
      .replaceAll('ё', 'е')
      .replaceAll(RegExp(r'[^\wа-я-]', unicode: true), '');

  static String normalize(String raw) => raw
      .toLowerCase()
      .replaceAll('ё', 'е')
      .replaceAll(RegExp(r'[^\wа-я\s-]', unicode: true), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  static bool _has(List<String> words, List<String> stems) =>
      words.any((w) => stems.any((s) => w.startsWith(s)));

  static int? _num(String w) {
    final n = numberWords[w];
    if (n != null) return n;
    return RegExp(r'^\d{1,2}$').hasMatch(w) ? int.parse(w) : null;
  }

  /// Основа слова для поиска по переписке: «долгами», «долги», «долгов» → «долг». Падежные окончания отбрасываются,
  /// но остаётся не меньше четырёх букв.
  static String searchStem(String word) {
    var w = normalizeWord(word);
    const ends = [
      'ами',
      'ями',
      'ого',
      'ому',
      'ыми',
      'ими',
      'ов',
      'ев',
      'ей',
      'ам',
      'ям',
      'ах',
      'ях',
      'ом',
      'ем',
      'ой',
      'ий',
      'ый',
      'ая',
      'яя',
      'ое',
      'ее',
      'ые',
      'ие',
      'ых',
      'их',
      'ую',
      'юю',
      'у',
      'ю',
      'а',
      'я',
      'ы',
      'и',
      'е',
      'о',
      'ь'
    ];
    var changed = true;
    while (changed && w.length > 4) {
      changed = false;
      for (final e in ends) {
        if (w.endsWith(e) && w.length - e.length >= 4) {
          w = w.substring(0, w.length - e.length);
          changed = true;
          break;
        }
      }
    }
    return w;
  }

  /// Слова поиска из фразы: без глаголов-просьб, слов про тип вложения и предлогов; в виде основ.
  static const _searchNoise = {
    'найди',
    'найти',
    'поищи',
    'ищи',
    'искать',
    'покажи',
    'показать',
    'где',
    'мне',
    'все',
    'всё',
    'какие',
    'какой',
    'есть',
    'у',
    'с',
    'со',
    'про',
    'о',
    'об',
    'по',
    'в',
    'на',
    'из',
    'от',
    'для',
    'за',
    'к',
    'мои',
    'моя',
    'мой',
    'этот',
    'этом',
    'чате',
    'переписке',
    'переписка',
  };
  static const _photoStems = [
    'фото',
    'фотограф',
    'картин',
    'изображен',
    'снимок',
    'снимк',
    'скрин'
  ];
  static const _fileStems = ['файл', 'документ', 'пдф', 'pdf', 'докум'];
  static const _audioStems = ['голосов', 'аудио', 'запис'];
  static const _videoStems = ['видео', 'кружок', 'кружк', 'ролик'];

  /// Разбор фразы [raw] в режиме [mode] (см. [VoiceMode]). `null` — не распознано.
  static VoiceIntent? parse(String raw, {String? mode}) {
    final rawTokens =
        raw.trim().split(RegExp(r'\s+')).where((t) => t.isNotEmpty).toList();
    final norm = [for (final t in rawTokens) normalizeWord(t)];
    final words = [
      for (final w in norm)
        if (w.isNotEmpty && !_fillers.contains(w)) w
    ];
    if (words.isEmpty) return null;
    final joined = words.join(' ');

    // ---- любой экран ----
    // Поиск в интернете.
    final web = RegExp(
            r'(найди|найти|поищи|ищи|посмотри|загугли|погугли|узнай).{0,25}(в интернете|в сети|в гугле|в google|в браузере)|(в интернете|в сети|в гугле|в google).{0,20}(найди|поищи|посмотри|узнай)|загугли|погугли')
        .hasMatch(joined);
    if (web) {
      final q = joined
          .replaceAll(
              RegExp(
                  r'(найди|найти|поищи|ищи|посмотри|загугли|погугли|узнай|пожалуйста)'),
              ' ')
          .replaceAll(RegExp(r'в (интернете|сети|гугле|google|браузере)'), ' ')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
      return VoiceIntent(VoiceAction.webSearch, query: q.isEmpty ? null : q);
    }
    // Запись в заметки (дневник), не заметка к выстрелу.
    final diary = RegExp(
            r'(запиши|записать|добавь|добавить|сохрани|положи|внеси).{0,15}(в заметк|в дневник)|(в заметки|в дневник)')
        .firstMatch(joined);
    if (diary != null) {
      // Текст — после слов «в заметки», по исходным словам (регистр и знаки сохраняются).
      final at = norm
          .indexWhere((w) => w.startsWith('заметк') || w.startsWith('дневник'));
      final text = at >= 0 && at < rawTokens.length - 1
          ? rawTokens
              .sublist(at + 1)
              .join(' ')
              .replaceFirst(RegExp(r'^[\s,.:;-]+'), '')
          : '';
      return VoiceIntent(VoiceAction.addDiaryNote,
          text: text.isEmpty ? null : text);
    }
    // Создать упражнение: «создай упражнение пневматика 40 выстрелов».
    if (RegExp(r'(создай|создать|добавь|добавить|заведи|сделай)')
            .hasMatch(joined) &&
        _has(words, ['упражнен', 'тренировк'])) {
      int? shots;
      for (var i = 0; i < words.length; i++) {
        if (words[i].startsWith('выстрел') && i > 0) shots = _num(words[i - 1]);
      }
      final face = _has(words, ['пистолет'])
          ? 'pistol_10m'
          : (_has(words, ['малокалибер', 'мелкокалибер']) ||
                  words.contains('50')
              ? 'rifle_50m'
              : 'rifle_10m');
      final title = rawTokens
          .where((t) => !RegExp(
                  r'^(создай|создать|добавь|добавить|заведи|сделай|упражнение|тренировку|пожалуйста)$',
                  caseSensitive: false)
              .hasMatch(normalizeWord(t)))
          .join(' ')
          .trim();
      return VoiceIntent(VoiceAction.createExercise,
          shots: shots, face: face, text: title.isEmpty ? null : title);
    }

    // ---- тренировка ----
    if (mode == VoiceMode.training) {
      final shot = _placeShot(rawTokens, norm);
      if (shot != null) return shot;
    }
    // ---- переписка ----
    if (mode == VoiceMode.chat) {
      final search = _chatSearch(words);
      if (search != null) return search;
    }

    // Заметка: всё, что после слова-команды, — текст заметки (к выстрелу в тренировке).
    final noteAt = words.indexWhere((w) =>
        w.startsWith('заметк') ||
        w.startsWith('запиши') ||
        w.startsWith('запись') ||
        w.startsWith('комментар'));
    if (noteAt >= 0) {
      final rest = words.sublist(noteAt + 1).join(' ').trim();
      return VoiceIntent(VoiceAction.addNote, text: rest.isEmpty ? null : rest);
    }
    // Вопрос ассистенту: «спроси …», «вопрос …».
    final askAt =
        words.indexWhere((w) => w.startsWith('спрос') || w == 'вопрос');
    if (askAt >= 0 && askAt < words.length - 1) {
      return VoiceIntent(VoiceAction.askAi,
          text: words.sublist(askAt + 1).join(' '));
    }

    final hasTraining = _has(words, ['тренировк', 'стрельб', 'упражнен']);
    // Режим концентрации (чёрный экран).
    if (joined.contains('концентрац') ||
        joined.contains('черный экран') ||
        (_has(words, ['фокус']) && !_has(words, ['открой']))) {
      return const VoiceIntent(VoiceAction.focusMode);
    }
    // Отмена выстрела.
    if (_has(words, ['отмен', 'удали', 'убери', 'сотри']) &&
        _has(words, ['выстрел', 'пробоин', 'последн', 'попадан'])) {
      return const VoiceIntent(VoiceAction.undoShot);
    }
    if (words.length == 1 && _has(words, ['отмен']))
      return const VoiceIntent(VoiceAction.undoShot);

    // Управление тренировкой.
    if (_has(words, ['пауз', 'приостанов']) ||
        (_has(words, ['останов']) && hasTraining))
      return const VoiceIntent(VoiceAction.trainingPause);
    if (_has(words, ['продолж', 'возобнов']))
      return const VoiceIntent(VoiceAction.trainingResume);
    if (_has(words, ['заверш', 'законч', 'финиш']) ||
        (joined.contains('стоп') && hasTraining))
      return const VoiceIntent(VoiceAction.trainingFinish);
    if (_has(words, ['начн', 'начин', 'начат', 'старт', 'поехал']) &&
        (hasTraining || words.length <= 2))
      return const VoiceIntent(VoiceAction.trainingStart);
    // Финал: «готов».
    if (words.length <= 2 && _has(words, ['готов']))
      return const VoiceIntent(VoiceAction.finalReady);

    // Назад.
    if (_has(words, ['назад', 'вернись', 'вернут', 'закрой', 'выйди']) &&
        !_has(words, ['тренировк', 'настройк', 'финал'])) {
      return const VoiceIntent(VoiceAction.back);
    }

    // Открыть раздел: глагол + название (или просто название раздела).
    String? target;
    for (final w in words) {
      for (final e in sections.entries) {
        if (w.startsWith(e.key)) target = e.value;
      }
    }
    if (target != null) return VoiceIntent(VoiceAction.open, target: target);
    return null;
  }

  /// «Десять пять на пять часов. Дернул пальцем…» → результат 10.5, направление 5 часов, заметка — остаток фразы.
  static VoiceIntent? _placeShot(List<String> rawTokens, List<String> norm) {
    // Направление: «на/в <число> час(а|ов)».
    var hourAt = -1;
    double? hour;
    for (var i = 0; i + 2 < norm.length; i++) {
      if ((norm[i] == 'на' || norm[i] == 'в') &&
          norm[i + 2].startsWith('час')) {
        final h = _num(norm[i + 1]);
        if (h != null && h >= 0 && h <= 12) {
          hourAt = i;
          hour = h.toDouble();
          break;
        }
      }
    }
    if (hour == null) return null;
    // Результат: числа перед направлением («десять пять», «10 5», «девять»).
    final nums = <int>[];
    for (var i = 0; i < hourAt; i++) {
      final n = _num(norm[i]);
      if (n != null) nums.add(n);
    }
    if (nums.isEmpty) return null;
    var score = nums.first.toDouble();
    if (nums.length >= 2 && nums[1] >= 0 && nums[1] <= 9) score += nums[1] / 10;
    if (score > 10.9) return null;
    // Заметка — всё после «часов» (исходные слова, без знака препинания в начале).
    final tail = rawTokens.length > hourAt + 3
        ? rawTokens
            .sublist(hourAt + 3)
            .join(' ')
            .replaceFirst(RegExp(r'^[\s,.:;!?-]+'), '')
        : '';
    return VoiceIntent(VoiceAction.placeShot,
        score: score, hour: hour, text: tail.isEmpty ? null : tail);
  }

  static VoiceIntent? _chatSearch(List<String> words) {
    if (!_has(words, ['найд', 'поищ', 'ищи', 'покаж', 'где'])) return null;
    String? filter;
    final content = <String>[];
    for (final w in words) {
      if (_searchNoise.contains(w) || w.length <= 1) continue;
      if (_photoStems.any(w.startsWith)) {
        filter = 'photo';
        continue;
      }
      if (_fileStems.any(w.startsWith)) {
        filter = 'file';
        continue;
      }
      if (_videoStems.any(w.startsWith)) {
        filter = 'video';
        continue;
      }
      if (_audioStems.any(w.startsWith)) {
        filter = 'audio';
        continue;
      }
      if (['найд', 'поищ', 'ищи', 'покаж'].any(w.startsWith)) continue;
      content.add(searchStem(w));
    }
    if (content.isEmpty && filter == null) return null;
    return VoiceIntent(VoiceAction.chatSearch,
        query: content.isEmpty ? null : content.join(' '), filter: filter);
  }
}
