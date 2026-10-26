/// Голосовые команды: разбор распознанной фразы в действие по правилам (без ИИ, бесплатно и мгновенно).
///
/// Правило универсальное, а не список готовых фраз: из фразы выбрасываются обращения и вежливость, потом ищутся
/// основы слов-глаголов и названия разделов — порядок и падеж не важны («покажи мне пожалуйста статистику»,
/// «статистику открой», «в настройки»). Всё, что не разобрано, уходит к ИИ-помощнику (если включён), который может
/// только выбрать действие из этого же закрытого списка.
enum VoiceAction {
  open, // открыть раздел: target — id вкладки
  back,
  trainingStart,
  trainingPause,
  trainingResume,
  trainingFinish,
  undoShot,
  addNote, // text — текст заметки
  focusMode,
  finalReady,
  askAi, // text — вопрос ассистенту
}

class VoiceIntent {
  final VoiceAction action;
  final String? target;
  final String? text;
  const VoiceIntent(this.action, {this.target, this.text});

  @override
  String toString() => 'VoiceIntent($action${target == null ? '' : ', $target'}${text == null ? '' : ', «$text»'})';

  @override
  bool operator ==(Object o) => o is VoiceIntent && o.action == action && o.target == target && o.text == text;

  @override
  int get hashCode => Object.hash(action, target, text);
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

  static const _fillers = {'пожалуйста', 'пж', 'мне', 'нам', 'ка', 'теперь', 'давай', 'давайте', 'нексус', 'эй', 'окей', 'слушай', 'ну', 'а', 'и'};

  static String normalize(String raw) => raw
      .toLowerCase()
      .replaceAll('ё', 'е')
      .replaceAll(RegExp(r'[^\wа-я\s-]', unicode: true), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  static bool _has(List<String> words, List<String> stems) => words.any((w) => stems.any((s) => w.startsWith(s)));

  /// Разбор фразы. `null` — не распознано.
  static VoiceIntent? parse(String raw) {
    final norm = normalize(raw);
    if (norm.isEmpty) return null;
    final words = [for (final w in norm.split(' ')) if (w.isNotEmpty && !_fillers.contains(w)) w];
    if (words.isEmpty) return null;
    final joined = words.join(' ');

    // Заметка: всё, что после слова-команды, — текст заметки.
    final noteAt = words.indexWhere((w) => w.startsWith('заметк') || w.startsWith('запиши') || w.startsWith('запись') || w.startsWith('комментар'));
    if (noteAt >= 0) {
      final rest = words.sublist(noteAt + 1).join(' ').trim();
      return VoiceIntent(VoiceAction.addNote, text: rest.isEmpty ? null : rest);
    }
    // Вопрос ассистенту: «спроси …», «вопрос …».
    final askAt = words.indexWhere((w) => w.startsWith('спрос') || w == 'вопрос');
    if (askAt >= 0 && askAt < words.length - 1) {
      return VoiceIntent(VoiceAction.askAi, text: words.sublist(askAt + 1).join(' '));
    }

    final hasTraining = _has(words, ['тренировк', 'стрельб', 'упражнен']);
    // Режим концентрации (чёрный экран).
    if (joined.contains('концентрац') || joined.contains('черный экран') || (_has(words, ['фокус']) && !_has(words, ['открой']))) {
      return const VoiceIntent(VoiceAction.focusMode);
    }
    // Отмена выстрела.
    if (_has(words, ['отмен', 'удали', 'убери', 'сотри']) && _has(words, ['выстрел', 'пробоин', 'последн', 'попадан'])) {
      return const VoiceIntent(VoiceAction.undoShot);
    }
    if (words.length == 1 && _has(words, ['отмен'])) return const VoiceIntent(VoiceAction.undoShot);

    // Управление тренировкой.
    if (_has(words, ['пауз', 'приостанов']) || (_has(words, ['останов']) && hasTraining)) return const VoiceIntent(VoiceAction.trainingPause);
    if (_has(words, ['продолж', 'возобнов'])) return const VoiceIntent(VoiceAction.trainingResume);
    if (_has(words, ['заверш', 'законч', 'финиш']) || (joined.contains('стоп') && hasTraining)) return const VoiceIntent(VoiceAction.trainingFinish);
    if (_has(words, ['начн', 'начин', 'начат', 'старт', 'поехал']) && (hasTraining || words.length <= 2)) return const VoiceIntent(VoiceAction.trainingStart);
    // Финал: «готов».
    if (words.length <= 2 && _has(words, ['готов'])) return const VoiceIntent(VoiceAction.finalReady);

    // Назад.
    if (_has(words, ['назад', 'вернись', 'вернут', 'закрой', 'выйди']) && !_has(words, ['тренировк', 'настройк', 'финал'])) {
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
}
