import '../i18n/i18n.dart';
/// Блоки экрана просмотра прошлой тренировки (раздел 8 ТЗ) — та же идея
/// перетаскиваемых/скрываемых блоков, что у `WorkspacePage` на рабочем
/// столе тренировки, только своя раскладка и свой набор.
///
/// Шапка (название упражнения + сумма) в список не входит — пользователь
/// явно отвёл ей отдельное фиксированное место "в шапке", а не блок.
enum ExerciseDetailBlock {
  target(/*tr*/ 'Мишень'),
  series(/*tr*/ 'Серии'),
  statistics(/*tr*/ 'Статистика'),
  chat(/*tr*/ 'Ассистент');

  const ExerciseDetailBlock(this._title);

  final String _title;

  /// Подпись на языке интерфейса (ключ перевода — русский текст).
  String get title => tr(_title);

  /// Мишень скрыть нельзя — тот же довод, что у `WorkspacePage.target`:
  /// без неё смотреть в принципе нечего.
  bool get canHide => this != ExerciseDetailBlock.target;

  static const List<ExerciseDetailBlock> defaultOrder = [
    ExerciseDetailBlock.target,
    ExerciseDetailBlock.series,
    ExerciseDetailBlock.statistics,
    ExerciseDetailBlock.chat,
  ];

  static ExerciseDetailBlock? byName(String name) {
    for (final b in ExerciseDetailBlock.values) {
      if (b.name == name) return b;
    }
    return null;
  }
}
