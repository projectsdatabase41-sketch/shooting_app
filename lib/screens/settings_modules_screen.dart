import '../logic/friendly_error.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../i18n/i18n.dart';
import '../services/modules_settings.dart';
import '../state/app_data_store.dart';
import '../widgets/glass_pill.dart';

/// «Модули»: необязательные части приложения. Выключенный модуль скрыт и
/// ничего не делает в фоне.
class SettingsModulesScreen extends StatefulWidget {
  const SettingsModulesScreen({super.key});

  @override
  State<SettingsModulesScreen> createState() => _SettingsModulesScreenState();
}

class _SettingsModulesScreenState extends State<SettingsModulesScreen> {
  /// Включает/выключает роль; хотя бы одна должна остаться.
  void _setRole(AppDataStore store, {bool? athlete, bool? coach}) {
    final a = athlete ?? store.isAthlete, c = coach ?? store.isCoach;
    if (!a && !c) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('Нужна хотя бы одна роль: тренировки или спортсмены'))));
      return;
    }
    store.isAthlete = a;
    store.isCoach = c;
    store.saveSettings();
    store.refreshView();
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppDataStore>();
    final db = store.db;
    final items = <(AppModule, IconData, String, String)>[
      (
        AppModule.messenger,
        Icons.forum_outlined,
        tr('Мессенджер'),
        tr('Чаты, вызов тренера, push-уведомления')
      ),
      (
        AppModule.assistant,
        Icons.auto_awesome_outlined,
        tr('ИИ Ассистент'),
        tr('Чаты с ИИ, помощники, поиск, режим мышления')
      ),
      (
        AppModule.localAi,
        Icons.offline_bolt_outlined,
        tr('Локальный ИИ'),
        tr('Модель на самом устройстве, без интернета')
      ),
      // Финалы пока только в режиме разработчика (рано публиковать).
      if (friendlyErrorDevMode)
        (
          AppModule.finals,
          Icons.emoji_events_outlined,
          tr('Финалы'),
          tr('Финалы по правилам ISSF с ботами и таблицей результатов')
        ),
      (
        AppModule.services,
        Icons.extension_outlined,
        tr('Сервисы'),
        tr('Свои плитки: Google Диск, Supabase, любые API')
      ),
    ];
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: GlassHeader(
        title: Text(tr('Модули'),
            style: Theme.of(context)
                .textTheme
                .titleMedium
                ?.copyWith(fontWeight: FontWeight.w600)),
      ),
      body: ListView(
        padding: EdgeInsets.only(
            top: MediaQuery.paddingOf(context).top + GlassHeader.height + 8),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              tr('Основа приложения — записи тренировок и заметки тренера. Остальное включается здесь; выключенный модуль скрыт и не работает в фоне.'),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          // Роли: можно быть спортсменом, тренером или обоими сразу.
          SwitchListTile(
            secondary: const Icon(Icons.fitness_center),
            title: Text(tr('Тренировки')),
            subtitle: Text(tr('Свои тренировки: мишень, упражнения, статистика')),
            value: store.isAthlete,
            onChanged: (v) => _setRole(store, athlete: v),
          ),
          SwitchListTile(
            secondary: const Icon(Icons.groups_outlined),
            title: Text(tr('Спортсмены')),
            subtitle: Text(tr('Режим тренера: дневники, результаты и задания подключённых спортсменов')),
            value: store.isCoach,
            onChanged: (v) => _setRole(store, coach: v),
          ),
          const Divider(height: 24),
          for (final (module, icon, title, subtitle) in items)
            SwitchListTile(
              secondary: Icon(icon),
              title: Text(title),
              subtitle: Text(subtitle),
              value: ModulesSettings.isOn(db, module),
              onChanged: (v) =>
                  setState(() => ModulesSettings.set(db, module, v)),
            ),
        ],
      ),
    );
  }
}
