import 'package:flutter/material.dart';

import '../widgets/home_tabs_bar.dart';

/// Все известные вкладки главного экрана, отдельно для каждого режима —
/// id хранится в настройках (`HomeTabsViewModel`), порядок здесь — это
/// порядок ПО УМОЛЧАНИЮ, до первой правки пользователем.
///
/// "Мишень" и "Настройки" нельзя скрыть: без "Мишени" негде записывать
/// выстрелы идущей тренировки, а без "Настроек" скрытые вкладки стало бы
/// неоткуда вернуть (см. `SettingsHomeTabsScreen`).
// 'trainings' больше не отдельная вкладка — по решению пользователя
// "Упражнения" и "Тренировки" объединены визуально в одну плитку: тап
// по упражнению в `ExercisesScreen` открывает список ЕГО тренировок
// (`TrainingsHistoryScreen(exercise: ...)`).
const athleteTabIds = ['exercises', 'target', 'statistics', 'assistant', 'messenger', 'settings'];
const athleteUnhidable = {'target', 'settings'};

const coachTabIds = ['diary', 'athletes', 'statistics_coach', 'assistant_coach', 'tasks', 'messenger', 'settings'];
const coachUnhidable = {'settings'};

/// Префикс id вкладки сервиса в `HomeTabsViewModel.allIds` — плитки
/// сервисов (`SettingsServicesScreen`) добавляются/убираются во время
/// работы приложения, поэтому их id не входят в списки выше, а
/// домешиваются к ним по этому префиксу (см. `HomeShell._onServicesChanged`).
const serviceTabPrefix = 'service_';

const Map<String, HomeTabSpec> homeTabSpecs = {
  'exercises': HomeTabSpec(icon: Icons.fitness_center, label: 'Упражнения'),
  'target': HomeTabSpec(icon: Icons.gps_fixed, label: 'Мишень'),
  'statistics': HomeTabSpec(icon: Icons.bar_chart, label: 'Статистика'),
  'assistant': HomeTabSpec(icon: Icons.auto_awesome_outlined, label: 'Ассистент'),
  'messenger': HomeTabSpec(icon: Icons.forum_outlined, label: 'Мессенджер'),
  'settings': HomeTabSpec(icon: Icons.settings_outlined, label: 'Настройки'),
  'diary': HomeTabSpec(icon: Icons.menu_book_outlined, label: 'Дневник'),
  'athletes': HomeTabSpec(icon: Icons.groups_outlined, label: 'Спортсмены'),
  'statistics_coach': HomeTabSpec(icon: Icons.bar_chart, label: 'Статистика'),
  'assistant_coach': HomeTabSpec(icon: Icons.auto_awesome_outlined, label: 'Ассистент'),
  'tasks': HomeTabSpec(icon: Icons.assignment_outlined, label: 'Задания'),
};
