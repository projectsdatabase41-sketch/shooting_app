/// Страницы рабочего стола тренировки.
///
/// Устроено как домашний экран Android (решение пользователя): страницы
/// листаются свайпом влево-вправо, порядок меняется перетаскиванием,
/// ненужные не удаляются, а ПРЯЧУТСЯ — и в любой момент возвращаются на
/// место. Удаления нет намеренно: страница здесь не документ
/// пользователя, а встроенный экран приложения, и «удалить статистику»
/// означало бы только «убрать с глаз».
enum WorkspacePage {
  target('Мишень'),
  statistics('Статистика'),
  shots('Выстрелы'),
  assistant('Ассистент'),
  notes('Заметки'),
  coach('Тренер');

  const WorkspacePage(this.title);

  final String title;

  /// Мишень скрыть нельзя: без неё тренировка перестаёт быть
  /// тренировкой, и пользователь остался бы на экране без способа
  /// записать выстрел.
  bool get canHide => this != WorkspacePage.target;

  /// Порядок и видимость по умолчанию: мишень посередине, слева от неё
  /// разбор, справа — общение. Пользователь просил свайп влево к
  /// статистике и вправо к ассистенту — это ровно такой порядок.
  static const List<WorkspacePage> defaultOrder = [
    WorkspacePage.statistics,
    WorkspacePage.target,
    WorkspacePage.assistant,
    WorkspacePage.shots,
    WorkspacePage.notes,
    WorkspacePage.coach,
  ];

  /// Что показано сразу после установки. Остальное лежит «за краем» и
  /// добавляется из обзора: пустой рабочий стол лучше перегруженного.
  static const List<WorkspacePage> defaultVisible = [
    WorkspacePage.statistics,
    WorkspacePage.target,
    WorkspacePage.assistant,
  ];

  static WorkspacePage? byName(String name) {
    for (final p in WorkspacePage.values) {
      if (p.name == name) return p;
    }
    return null;
  }
}
