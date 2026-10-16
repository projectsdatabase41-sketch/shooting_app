import 'package:flutter/material.dart';

import '../widgets/home_tabs_bar.dart';

/// Все известные вкладки главного экрана, отдельно для каждого режима —
/// id хранится в настройках (`HomeTabsViewModel`), порядок здесь — это
/// порядок ПО УМОЛЧАНИЮ, до первой правки пользователем.
///
/// "Тренировка" и "Настройки" нельзя скрыть: без "Тренировки" негде записывать
/// выстрелы идущей тренировки (плитка открывает запущенную, а без запущенной
/// — список упражнений), а без "Настроек" скрытые вкладки стало бы
/// неоткуда вернуть (см. `SettingsModulesScreen`).
// Режимов «спортсмен / тренер» больше нет: есть набор рабочих пространств
// (вкладок), каждое принадлежит модулю; пользователь включает модули и
// расставляет их по приоритету в «Модулях». Показ вкладки определяется
// её модулем (см. `HomeShell`).
//
// 'trainings' не отдельная вкладка: «Упражнения» и «Тренировки» объединены
// в одну плитку.
const allTabIds = [
  'exercises', // модуль «Тренировки»
  'statistics', // модуль «Тренировки»
  'tasks', // модуль «Тренировки» (задания спортсмену)
  'athletes', // модуль «Спортсмены»
  'statistics_coach', // модуль «Спортсмены»
  'tasks_coach', // модуль «Спортсмены»
  'assistant', // модуль «ИИ Ассистент»
  'assistant_coach', // «ИИ Ассистент» + «Спортсмены»
  'notes', // модуль «Заметки»
  'finals', // модуль «Финалы» (режим разработчика)
  'messenger', // модуль «Мессенджер»
  'settings',
];

/// Нельзя скрыть: без «Настроек» вкладки неоткуда вернуть.
const unhidableTabs = {'settings'};

/// Вкладки, работающие с данными подключённых спортсменов (контекст «тренер»).
const coachTabSet = {'athletes', 'statistics_coach', 'tasks_coach', 'assistant_coach'};

/// Префикс id вкладки сервиса в `HomeTabsViewModel.allIds` — плитки
/// сервисов (`SettingsServicesScreen`) добавляются/убираются во время
/// работы приложения, поэтому их id не входят в списки выше, а
/// домешиваются к ним по этому префиксу (см. `HomeShell._onServicesChanged`).
const serviceTabPrefix = 'service_';

const Map<String, HomeTabSpec> homeTabSpecs = {
  'exercises':
      HomeTabSpec(icon: Icons.fitness_center, label: /*tr*/ 'Тренировка'),
  'statistics': HomeTabSpec(icon: Icons.bar_chart, label: /*tr*/ 'Статистика'),
  'tasks':
      HomeTabSpec(icon: Icons.assignment_outlined, label: /*tr*/ 'Задания'),
  'athletes':
      HomeTabSpec(icon: Icons.groups_outlined, label: /*tr*/ 'Спортсмены'),
  'statistics_coach': HomeTabSpec(
      icon: Icons.stacked_bar_chart, label: /*tr*/ 'Статистика спортсменов'),
  'tasks_coach': HomeTabSpec(
      icon: Icons.assignment_ind_outlined, label: /*tr*/ 'Задания спортсменам'),
  'assistant':
      HomeTabSpec(icon: Icons.auto_awesome_outlined, label: /*tr*/ 'Ассистент'),
  'assistant_coach': HomeTabSpec(
      icon: Icons.psychology_outlined, label: /*tr*/ 'Ассистент тренера'),
  'notes':
      HomeTabSpec(icon: Icons.sticky_note_2_outlined, label: /*tr*/ 'Заметки'),
  'finals':
      HomeTabSpec(icon: Icons.emoji_events_outlined, label: /*tr*/ 'Финалы'),
  'messenger':
      HomeTabSpec(icon: Icons.forum_outlined, label: /*tr*/ 'Мессенджер'),
  'settings':
      HomeTabSpec(icon: Icons.settings_outlined, label: /*tr*/ 'Настройки'),
};
